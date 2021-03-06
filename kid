#!/bin/bash
#
# kid is a helper script for launching Kubernetes in Docker

KUBERNETES_VERSION=1.2.4
KUBERNETES_API_PORT=8080
KUBERNETES_DASHBOARD_NODEPORT=31999
KUBERNETES_DNS_IP=10.0.0.10
KUBERNETES_DNS_DOMAIN=cluster.local
DNS_HOST_ENDPOINT=$(echo $DOCKER_HOST | awk -F'[/:]' '{print $4}')
: ${DNS_HOST_ENDPOINT:=$(ifconfig docker0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')}
#DNS_HOST_ENDPOINT=172.17.0.1

set -e

function print_usage {
    cat << EOF
kid is a utility for launching Kubernetes in Docker

Usage: kid [command]

Available commands:
  up       Starts Kubernetes in the Docker host currently configured with your local docker command
  down     Tear down a previously started Kubernetes cluster leaving Deployments and Replica Sets intact
  restart  Restart Kubernetes
  purge    Removes all Deployments, Replica Sets, Replication Controllers, Services, Pods, and Namespaces
EOF
}



function check_prerequisites {
    function require_command_exists() {
        command -v "$1" >/dev/null 2>&1 || \
	    { echo "$1 is required but is not installed. Aborting." >&2; exit 1; }
    }
    require_command_exists kubectl
    require_command_exists docker
    docker info > /dev/null
    if [ $? != 0 ]; then
        echo A running Docker engine is required. Is your Docker host up?
        exit 1
    fi
}

function active_docker_machine {
    if [ $(command -v docker-machine) ]; then
        docker-machine active
    fi
}

function forward_port_if_necessary {
    local port=$1
    local machine=$(active_docker_machine)

    if [ -n "$machine" ]; then
        if ! pgrep -f "ssh.*$port:localhost" > /dev/null; then
            docker-machine ssh "$machine" -f -N -L "$port:localhost:$port"
        else
            echo Did not set up port forwarding to the Docker machine: An ssh tunnel on port $port already exists. The kubernetes cluster may not be reachable from local kubectl.
        fi
    fi
}

function remove_port_forward_if_forwarded {
    local port=$1
    pkill -f "ssh.*docker.*$port:localhost:$port"
}

function wait_for_kubernetes {
    until $(kubectl cluster-info &> /dev/null); do
        sleep 1
    done
}

function check_for_kubernetes {
    result=$(kubectl cluster-info &> /dev/null)
    if [ -z "$result" ];
    then
      return 0
    else
      return 1
    fi
}

function check_for_docker_containers {
    result=$(docker ps -aq &> /dev/null)
    if [ -z $result ];
    then
      return 0
    else
      return 1
    fi
}

function create_kube_system_namespace {
    kubectl create -f - << EOF > /dev/null
kind: Namespace
apiVersion: v1
metadata:
  name: kube-system
  labels:
    name: kube-system
EOF
}

function activate_kubernetes_dns {
    local dns_ip=$1
    local dns_domain=$2
    local dns_endpoint=$3

    kubectl create -f - << EOF > /dev/null
kind: List
apiVersion: v1
items:
- kind: ReplicationController
  apiVersion: v1
  metadata:
    name: kube-dns-v11
    namespace: kube-system
    labels:
      k8s-app: kube-dns
      version: v11
      kubernetes.io/cluster-service: "true"
  spec:
    replicas: 1
    selector:
      k8s-app: kube-dns
      version: v11
    template:
      metadata:
        labels:
          k8s-app: kube-dns
          version: v11
          kubernetes.io/cluster-service: "true"
      spec:
        hostNetwork: true
        containers:
        - name: kube2sky
          image: gcr.io/google_containers/kube2sky:1.14
          resources:
            limits:
              cpu: 100m
              # Kube2sky watches all pods.
              memory: 200Mi
            requests:
              cpu: 100m
              memory: 50Mi
          args:
          # command = "/kube2sky"
          - --domain=${dns_domain}
        - name: skydns
          image: gcr.io/google_containers/skydns:2015-10-13-8c72f8c
          resources:
            limits:
              cpu: 100m
              memory: 200Mi
            requests:
              cpu: 100m
              memory: 50Mi
          args:
          # command = "/skydns"
          - -machines=http://127.0.0.1:4001
          - -addr=0.0.0.0:53
          - -ns-rotate=false
          - -domain=${dns_domain}
          ports:
          - containerPort: 53
            name: dns
            protocol: UDP
          - containerPort: 53
            name: dns-tcp
            protocol: TCP
        dnsPolicy: Default  # Don't use cluster DNS.
- kind: Endpoints
  apiVersion: v1
  metadata:
    name: kube-dns
    namespace: kube-system
  subsets:
  - addresses:
    - ip: ${dns_endpoint}
    ports:
    - port: 53
      protocol: UDP
      name: dns
- kind: Service
  apiVersion: v1
  metadata:
    name: kube-dns
    namespace: kube-system
  spec:
    clusterIP: 10.0.0.10
    ports:
    - name: dns
      port: 53
      protocol: UDP
EOF
}

function activate_kubernetes_dashboard {
    local dashboard_service_nodeport=$1
    kubectl create -f - << EOF > /dev/null
# Source: https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/kubernetes-dashboard-canary.yaml
kind: List
apiVersion: v1
items:
- kind: ReplicationController
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
      version: canary
    name: kubernetes-dashboard-canary
    namespace: kube-system
  spec:
    replicas: 1
    selector:
      app: kubernetes-dashboard-canary
      version: canary
    template:
      metadata:
        labels:
          app: kubernetes-dashboard-canary
          version: canary
      spec:
        containers:
        - name: kubernetes-dashboard-canary
          image: gcr.io/google_containers/kubernetes-dashboard-amd64:canary
          imagePullPolicy: Always
          ports:
          - containerPort: 9090
            protocol: TCP
          args:
            # Uncomment the following line to manually specify Kubernetes API server Host
            # If not specified, Dashboard will attempt to auto discover the API server and connect
            # to it. Uncomment only if the default does not work.
            # - --apiserver-host=http://my-address:port
          livenessProbe:
            httpGet:
              path: /
              port: 9090
            initialDelaySeconds: 30
            timeoutSeconds: 30
- kind: Service
  apiVersion: v1
  metadata:
    labels:
      app: kubernetes-dashboard-canary
    name: dashboard-canary
    namespace: kube-system
  spec:
    type: NodePort
    ports:
    - port: 80
      targetPort: 9090
      nodePort: $dashboard_service_nodeport  # Addition. Not present in upstream definition.
    selector:
      app: kubernetes-dashboard-canary
    type: NodePort
EOF
}

function start_kubernetes {
    local kubernetes_version=$1
    local kubernetes_api_port=$2
    local dashboard_service_nodeport=$3
    local dns_ip=$4
    local dns_domain=$5
    local dns_endpoint=$6

    check_prerequisites

    if kubectl cluster-info 2> /dev/null; then
        echo kubectl is already configured to use an existing cluster
        exit 1
    fi

    docker run \
        --name=k8s_kubelet \
        --volume=/:/rootfs:ro \
        --volume=/sys:/sys:ro \
        --volume=/var/lib/docker/:/var/lib/docker:rw \
        --volume=/var/lib/kubelet/:/var/lib/kubelet:rw \
        --volume=/var/run:/var/run:rw \
        --net=host \
        --pid=host \
        --privileged=true \
        -d \
        gcr.io/google_containers/hyperkube-amd64:v${kubernetes_version} \
        /hyperkube kubelet \
            --containerized \
            --hostname-override="127.0.0.1" \
            --address="0.0.0.0" \
            --api-servers=http://localhost:${kubernetes_api_port} \
            --config=/etc/kubernetes/manifests \
            --cluster-dns=${dns_ip} \
            --cluster-domain=${dns_domain} \
            --allow-privileged=true --v=2 \
	    > /dev/null

    # TODO: Set and use a `kid` Kubernetes context instead of forwarding the port?
    forward_port_if_necessary $kubernetes_api_port

    echo Waiting for Kubernetes cluster to become available...
    wait_for_kubernetes
    sleep 1
    create_kube_system_namespace
    activate_kubernetes_dashboard $dashboard_service_nodeport
    activate_kubernetes_dns $dns_ip $dns_domain $dns_endpoint
    echo Kubernetes cluster is up. The Kubernetes dashboard can be accessed via HTTP at port $dashboard_service_nodeport of your Docker host.
}

function delete_kubernetes_resources {
    kubectl delete namespace kube-system > /dev/null 2>&1 || :
    kubectl delete replicationcontrollers,services,pods,secrets --all > /dev/null 2>&1 || :
    kubectl delete replicationcontrollers,services,pods,secrets --all --namespace=kube-system > /dev/null 2>&1 || :
    kubectl delete namespace kube-system > /dev/null 2>&1 || :
}

function purge_kubernetes_resources {
    kubectl delete namespace kube-system > /dev/null 2>&1 || :
    kubectl delete deployments,replicasets,replicationcontrollers,services,pods,secrets --all > /dev/null 2>&1 || :
    kubectl delete deployments,replicasets,replicationcontrollers,services,pods,secrets --all --namespace=kube-system > /dev/null 2>&1 || :
    kubectl delete namespace kube-system > /dev/null 2>&1 || :
}

function delete_kubelet_containers {
    # Remove the kubelet first so that it doesn't restart pods that we're going to remove next
    docker stop k8s_kubelet > /dev/null 2>&1
    docker rm -fv k8s_kubelet > /dev/null 2>&1

    k8s_containers=$(docker ps -aqf "name=k8s_")
    if [ ! -z "$k8s_containers" ]; then
        docker stop $k8s_containers > /dev/null 2>&1
        docker wait $k8s_containers > /dev/null 2>&1
        docker rm -fv $k8s_containers > /dev/null 2>&1
    fi
}

function delete_docker_containers {

    docker_containers=$(docker ps -aq)

    if [ ! -z "$docker_containers" ]; then
        while [ ! -z "$docker_containers" ]; do
	   docker stop $(docker ps -aq) > /dev/null 2>&1 || :
           docker wait $(docker ps -aq) || :
           docker rm -fv $(docker ps -aq) > /dev/null 2>&1 || :
           docker_containers=$(docker ps -aq) || :
        done
    fi
}

function purge_kubernetes {
  local kubernetes_api_port=$1
  purge_kubernetes_resources
  delete_kubelet_containers
  delete_docker_containers
  remove_port_forward_if_forwarded $kubernetes_api_port
}

function stop_kubernetes {
    local kubernetes_api_port=$1
    delete_kubernetes_resources
    delete_kubelet_containers
    remove_port_forward_if_forwarded $kubernetes_api_port
    delete_docker_containers
}



if [ "$1" == "up" ]; then
    start_kubernetes $KUBERNETES_VERSION $KUBERNETES_API_PORT $KUBERNETES_DASHBOARD_NODEPORT $KUBERNETES_DNS_IP $KUBERNETES_DNS_DOMAIN $DNS_HOST_ENDPOINT
elif [ "$1" == "down" ]; then
    # TODO: Ensure current Kubernetes context is set to local Docker (or Docker Machine VM) before downing
    stop_kubernetes $KUBERNETES_API_PORT
elif [ "$1" == "restart" ]; then
    # TODO: Check if not currently running before downing. Show a message if not running.
    kid down && kid up
elif [ "$1" == "purge" ]; then
    purge_kubernetes
elif [ "$1" == "systemd" ]; then
    #used only for systemd to restart pods automatically on hard reboot. Kill most everything except etcd to maintain persistance.
      if [ check_for_docker_containers ];then 
         delete_docker_containers
      fi
else
    print_usage
fi
