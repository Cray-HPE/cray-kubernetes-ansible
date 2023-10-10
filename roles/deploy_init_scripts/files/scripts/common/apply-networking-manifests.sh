#!/bin/bash

. /srv/cray/resources/common/vars.sh
export PODS_CIDR=$(craysys metadata get kubernetes-pods-cidr)
export WEAVE_MTU=$(craysys metadata get kubernetes-weave-mtu)
export K8S_VIP=$(craysys metadata get k8s_virtual_ip)
export CILIUM_OPERATOR_REPLICAS=$(craysys metadata get cilium-operator-replicas 2>/dev/null || echo "1")
export K8S_CNI=$(craysys metadata get k8s-primary-cni 2>/dev/null || echo "weave")
export CILIUM_KUBE_PROXY_REPLACEMENT=$(craysys metadata get cilium-kube-proxy-replacement 2>/dev/null || echo "disabled")

function apply_weave_manifest () {

  if [ -z ${PODS_CIDR} ]; then
    echo "kubernetes-pods-cidr not defined in cloud-init"
    return 1
  fi

  if [ -z ${WEAVE_MTU} ]; then
    echo "kubernetes-weave-mtu not defined in cloud-init"
    return 1
  fi

  echo "Installing/Updating Kubernetes CNI w/ pod cidr ${PODS_CIDR}, MTU: ${WEAVE_MTU}"
  envsubst < /srv/cray/resources/common/weave.yaml > /etc/cray/kubernetes/weave.yaml
  kubectl apply -f /etc/cray/kubernetes/weave.yaml

  echo "Wait for Weave Net to be ready..."
  kubectl rollout status daemonset weave-net -n kube-system
}

function install_cilium () {

  if [ -z ${PODS_CIDR} ]; then
    echo "kubernetes-pods-cidr not defined in cloud-init"
    return 1
  fi

  if [ -z ${K8S_VIP} ]; then
    echo "k8s_virtual_ip not defined in cloud-init"
    return 1
  fi

  if [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" != "disabled" ]; then
    # When we upgrade to k8s 1.22, we can skip the kube-proxy phase in the kubeadm config (CASMPET-6138)
    kubectl -n kube-system get ds kube-proxy > /dev/null 2>&1
    if [ $? -eq 0 ]; then
       echo "Removing kube-proxy"
       kubectl -n kube-system delete ds kube-proxy
       kubectl -n kube-system delete cm kube-proxy
    fi
  fi

  envsubst < /srv/cray/resources/common/cilium-cli-helm-values.yaml > /etc/cray/kubernetes/cilium-cli-helm-values.yaml

  if [ "${CILIUM_KUBE_PROXY_REPLACEMENT}" == "disabled" ]; then
    echo "Installing Cilium version ${CILIUM_CNI_VERSION} with pod cidr ${PODS_CIDR}, kube-proxy replacement ${CILIUM_KUBE_PROXY_REPLACEMENT}"
    helm install -f /etc/cray/kubernetes/cilium-cli-helm-values.yaml cilium /srv/cray/resources/common/cilium-${CILIUM_CNI_VERSION} --namespace kube-system
  else
    echo "Installing Cilium version ${CILIUM_CNI_VERSION} with pod cidr ${PODS_CIDR}, kube-proxy replacement ${CILIUM_KUBE_PROXY_REPLACEMENT}, k8s VIP: ${K8S_VIP}"
    helm install -f /etc/cray/kubernetes/cilium-cli-helm-values.yaml cilium /srv/cray/resources/common/cilium-${CILIUM_CNI_VERSION} --namespace kube-system --set kubeProxyReplacement=${CILIUM_KUBE_PROXY_REPLACEMENT} --set k8sServiceHost=${K8S_VIP} --set k8sServicePort=6442
  fi

  echo "Wait for Cilium to be ready..."
  kubectl wait deployment -n kube-system cilium-operator --for condition=Available=True --timeout=30s
  kubectl wait pods -n kube-system -l k8s-app=cilium --for condition=Ready --timeout=90s
}

function delete_stuck_multus_pod () {
  read -r pod_name pod_state < <(kubectl get pod -n kube-system -l 'app=multus' | grep Terminating | head -1l | awk '{print $1 " " $3}')
  if [ "$pod_state" == "Terminating" ]; then
    echo "Deleting $pod_name stuck terminating..."
    kubectl delete pod -n kube-system $pod_name --force --grace-period=0 > /dev/null 2>&1
  fi
}

function wait_for_multus_rollout() {
  echo "Wait for Multus Daemonset rollout to complete..."
  #
  # Give the K8S ten minutes to roll through the pods
  #
  kubectl rollout status daemonset --timeout='10m' kube-multus-ds -n kube-system > /dev/null 2>&1
  if [ "$?" -eq 0 ]; then
    echo "Multus Daemonset rollout is complete."
    return
  fi

  #
  # Rollout not done after ten minutes, let's terminate pods that are stuck
  #
  while true; do
    kubectl rollout status daemonset --timeout='1m' kube-multus-ds -n kube-system > /dev/null 2>&1
    if [ "$?" -ne 0 ]; then
      delete_stuck_multus_pod
    else
      echo "Multus Daemonset rollout is complete."
      break
    fi
  done
}

function apply_multus_manifest () {

  if [ "${K8S_CNI}" == "cilium" ]; then
    echo "Installing Multus DaemonSet for Cilium"
    export MULTUS_CONF=$(cat /srv/cray/resources/common/multus/multus-cilium.conf)
  else
    echo "Installing Multus DaemonSet for Weave"
    export MULTUS_CONF=$(cat /srv/cray/resources/common/multus/multus-weave.conf)
  fi

  envsubst < /srv/cray/resources/common/multus/multus-daemonset.yml > /etc/cray/kubernetes/multus-daemonset.yml
  kubectl apply -f /etc/cray/kubernetes/multus-daemonset.yml
  if [ "${K8S_CNI}" == "cilium" ]; then
    echo "Installing cilium net-attach-def"
    cp /srv/cray/resources/common/cilium-net-attach-def.yml /etc/cray/kubernetes/cilium-net-attach-def.yml
    kubectl apply -f /etc/cray/kubernetes/cilium-net-attach-def.yml
  fi
  wait_for_multus_rollout

  if kubectl get daemonsets -n kube-system kube-multus-ds-amd64 > /dev/null 2>&1; then
    echo "Removing previous Multus Daemonset."
    kubectl -n kube-system delete daemonset kube-multus-ds-amd64
    while kubectl get pods -n kube-system -l app=multus | grep -q Terminating; do
      delete_stuck_multus_pod
    done
  fi
}

if [ "${K8S_CNI}" == "cilium" ]; then
  install_cilium || exit 1
else
  apply_weave_manifest || exit 1
fi
apply_multus_manifest
