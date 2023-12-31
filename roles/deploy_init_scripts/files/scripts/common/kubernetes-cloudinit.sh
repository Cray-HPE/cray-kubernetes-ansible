#!/bin/bash
#
# MIT License
#
# (C) Copyright 2022-2023 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

set -e

if [ -f /root/zero.file ]; then rm /root/zero.file; fi

. /srv/cray/resources/vars.sh
export KUBECONFIG=/etc/kubernetes/admin.conf
# TODO: export CRAYSYS_TYPE=$(craysys type get)
export CRAYSYS_TYPE="metal"
# TODO: export DOMAIN=$(craysys metadata get domain)
export DOMAIN="nmn mtl hmn"
. /srv/cray/scripts/${CRAYSYS_TYPE}/lib.sh
export KUBERNETES_VERSION="v$(cat /etc/cray/kubernetes/version)"
export ETCD_INITIAL_CLUSTER_STRING=$(get-etcd-initial-cluster-members)
export BACKUP_ENDPOINTS_FOR_ETCD=$(get-etcdctl-backup-endpoints)
#TODO: export K8S_CNI=$(craysys metadata get k8s-primary-cni)
export K8S_CNI="weave"
# TODO: export SYSTEM_NAME=$(craysys metadata get system-name)
export SYSTEM_NAME="k8s-vm-worker"
# TODO: export SITE_DOMAIN=$(craysys metadata get site-domain)
export SITE_DOMAIN="hpc.amslabs.hpecorp.net"
initialized_file="/etc/cray/kubernetes/initialized"

# Script constants to reduce copypasta
K8S_PREFIX=/etc/cray/kubernetes

#
# Expand the root disk (vshasta only)
#
expand-root-disk

. /srv/cray/scripts/common/auditing_config.sh
echo "Configuring node auditing software"
configure_auditing

# These stop/starts may not be needed, they were added to ensure containerd and kubelet acknowledge
# their overlayFS.
systemctl stop containerd kubelet # TODO: spire-agent
systemctl enable containerd kubelet # TODO: spire-agent
systemctl start containerd kubelet # TODO: spire-agent || echo "a daemon didn't start initially but may later"

function mark-initialized() {
  echo "Marking this Kubernetes node as initialized"
  touch $initialized_file
}

function add-etcd-defrag-cron() {
  if [[ "$(hostname)" =~ ^ncn-m ]]; then
    echo "Setting up a cronjob to defrag bare-metal etcd on master nodes"
    #
    # Staggering when these run by an hour based on node number..
    #
    this_host=$(hostname)
    node_num=${this_host: -1}
    echo "0 ${node_num} * * * root etcdctl --endpoints https://127.0.0.1:2379 --cert /etc/kubernetes/pki/etcd/peer.crt --key /etc/kubernetes/pki/etcd/peer.key --cacert /etc/kubernetes/pki/etcd/ca.crt --command-timeout=600s defrag >> /var/log/cray/cron.log 2>&1" > /etc/cron.d/cray-etcd-defrag-cron
  else
    echo "Skipping setting up a cronjob to defrag bare-metal etcd since we're running on a worker"
  fi
}

function add-oidc-cronjob() {
  echo "Setting up a job to ensure oidc.pem file is kept up-to-date"
  echo "*/2 * * * * root /srv/cray/scripts/common/verify-oidc-pem.sh >> /var/log/cray/cron.log 2>&1" > /etc/cron.d/cray-verify-oidc-pem
}

function restart-daemons() {
  if [ ! -z "$NETWORK_DAEMONS" ]; then
    echo "Restarting network daemons..."
    systemctl restart ${NETWORK_DAEMONS}
  fi
  echo "Restarting containerd, kubelet, and cron daemons..."
  systemctl restart containerd kubelet cron
}

function wait-for-remote-file() {
  local hostname_source="$1"
  local local_destination="$2"
  local expected_content="$3"
  local remote_call_interval="$4"
  local remote_content=""
  local content_mismatch_count=0
  if [ ! -f $local_destination ]; then
    touch $local_destination
  fi
  while ! cat $local_destination | grep ''"$expected_content"'' >/dev/null 2>&1; do
    content_mismatch_count=$((content_mismatch_count+1))
    if [ $content_mismatch_count -gt 1 ]; then
      sleep $remote_call_interval
    fi
    while ! scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $hostname_source $local_destination >/dev/null 2>&1; do
      sleep $remote_call_interval
    done
  done
}

# Only applicable to control plane nodes, sets up
# /etc/cray/kubernetes/encryption as needed as the kubelet process now has a
# switch that requires the files to be present when things are started.
function setup-encryption() {
  # Note encryption files/setup is in its own sub directory to ensure the
  # daemonset doesn't need to possibly have access to any other data than it
  # truly needs.
  echo "Installing default encryption configuration setup"
  k8s_encryptiondir="${K8S_PREFIX}/encryption"
  install -dm755 "${k8s_encryptiondir}"
  install -m400 /srv/cray/resources/common/encryption-configuration.yaml "${k8s_encryptiondir}/default.yaml"

  # This is a nop setup for now, the current encryption is default/identity
  # encryption which doesn't differ with anything today. Just lets etcd writes
  # to go through the encryption machinery.
  #
  # Note: Only symlink current to default if isn't already pointing there. If it
  # points elsewhere that will indicate encryption is on
  current="${k8s_encryptiondir}/current.yaml"
  default="${k8s_encryptiondir}/default.yaml"

  if [ ! -h "${current}" ]; then
    # Initial setup, symlink current to default (identity)
    echo ln -sf "${default}" "${current}"
    ln -sf "${default}" "${current}"
  elif [ -h "${current}" ]; then
    # This is for the readlink, no amount of quoting satisfies shellcheck with it.
    #shellcheck disable=SC2086
    dest="$(readlink -f ${current})"
    if [ "${dest}" != "${default}" ]; then
      echo "note: k8s encryption is on using ${dest}"
    else
      echo "note: k8s encryption is off"
    fi
  else
    echo "fatal: encryption configuration is in an invalid state ${current} is not a symlink, k8s will not start"
    exit 1
  fi
}

function join() {
  local join_script_remote="$1"
  local join_script_local="/etc/cray/kubernetes/join.sh"
  echo "Waiting for the first Kubernetes control plane node to have a valid join script available at ${join_script_remote}..."
  wait-for-remote-file "${FIRST_MASTER_HOSTNAME}:${join_script_remote}" "${join_script_local}" "kubeadm join" 5

  #
  # If we're a master joining the cluster, be sure to explicitly set the apiserver-advertise-address argument
  #
  if [[ "$(hostname)" =~ ^ncn-m ]]; then
    echo "$(cat ${join_script_local}) --apiserver-advertise-address=${K8S_NODE_IP}" > ${join_script_local}
    # All other control-plane nodes need encryption setups as well.
    setup-encryption
  fi

  chmod 0700 $join_script_local
  echo "Attempting to join node to the Kubernetes cluster (will continue to retry if it fails)"
  echo "$(cat $join_script_local)..."
  while ! $join_script_local; do
    kubeadm reset -f || true
    #
    # Reset clobbers /etc/kubernetes/pki, make sure
    # stuff managed there is reset as well.
    #
    pre-configure-node
    sleep 10
    if [[ "$(hostname)" =~ ^ncn-m ]]; then
      configure-external-etcd
    fi
  done
}

function get-kube-config() {
  echo "Waiting for a valid KUBECONFIG file to be available from the first master..."
  wait-for-remote-file "${FIRST_MASTER_HOSTNAME}:${KUBECONFIG}" "${KUBECONFIG}" "apiVersion" 10
}

function set_conntrack_liberal() {
  echo "Setting net.netfilter.nf_conntrack_tcp_be_liberal to 1..."
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1
}

function check_master_taint() {
  master_taint="node-role.kubernetes.io/master:NoSchedule"
  if kubectl get node $(hostname) -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}' | grep -q "${master_taint}"; then
    echo "${master_taint} taint found on $(hostname)"
  else
    echo "${master_taint} taint NOT FOUND on $(hostname)"
    echo "Adding taint..."
    kubectl taint nodes $(hostname) ${master_taint}
    echo "Taints on $(hostname)..."
    kubectl get node $(hostname) -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}'
  fi
}

function set_system_domain_env() {

  # failing quietly for now while we test this out
  if [ -z "${SYSTEM_NAME}" ]; then
    echo "SYSTEM_NAME not defined in craysys"
    return
  fi

  if [ -z "${SITE_DOMAIN}" ]; then
    echo "SITE_DOMAIN not defined in craysys"
    return
  fi

  sed -i '/^SYSTEM_NAME=/d' /etc/environment || true
  echo "SYSTEM_NAME=${SYSTEM_NAME}" >> /etc/environment
  sed -i '/^SITE_DOMAIN=/d' /etc/environment || true
  echo "SITE_DOMAIN=${SITE_DOMAIN}" >> /etc/environment
  sed -i '/^SYSTEM_DOMAIN=/d' /etc/environment || true
  echo "SYSTEM_DOMAIN=${SYSTEM_NAME}.${SITE_DOMAIN}" >> /etc/environment

}

function post-join() {
  # node_type one of: first-master, master, worker
  local node_type="$1"

  set_system_domain_env

  if [[ "$node_type" == "master" ]]; then
    configure-load-balancer-for-master
    get-kube-config
    reconfigure-kube-api-server
    reconfigure-kube-scheduler
    reconfigure-kube-controller
    populate-tenant-admin-conf
    add-oidc-cronjob
    add-etcd-defrag-cron
    check_master_taint

    complete-initialization
    /srv/cray/scripts/common/prep-for-etcd-backup.sh ${BACKUP_ENDPOINTS_FOR_ETCD} ${RGW_VIRTUAL_IP}
  elif [[ "$node_type" == "first-master" ]]; then
    echo "Setting cluster-stored certs to be refreshed periodically to support HA and joining at any time by new members"
    mkdir -p /srv/cray/scripts/kubernetes
    cat > /srv/cray/scripts/kubernetes/token-certs-refresh.sh <<'EOF'
#!/bin/bash

export KUBECONFIG=/etc/kubernetes/admin.conf

if [[ "$1" != "skip-upload-certs" ]]; then
  kubeadm init phase upload-certs --upload-certs --config /etc/cray/kubernetes/kubeadm.yaml
fi
kubeadm token create --print-join-command > /etc/cray/kubernetes/join-command 2>/dev/null
echo "$(cat /etc/cray/kubernetes/join-command) --control-plane --certificate-key $(cat /etc/cray/kubernetes/certificate-key)" \
  > /etc/cray/kubernetes/join-command-control-plane
chmod 0700 /etc/cray/kubernetes/join-command
chmod 0700 /etc/cray/kubernetes/join-command-control-plane

EOF
    chmod +x /srv/cray/scripts/kubernetes/token-certs-refresh.sh
    /srv/cray/scripts/kubernetes/token-certs-refresh.sh skip-upload-certs
    echo "0 */1 * * * root /srv/cray/scripts/kubernetes/token-certs-refresh.sh >> /var/log/cray/cron.log 2>&1" > /etc/cron.d/cray-k8s-token-certs-refresh
    echo "Triggering the distribution of resources to other nodes (will continue to retry if it fails)"
    while ! /srv/cray/scripts/common/distribute.sh; do
      sleep 5
    done
    echo "Setting up a job to re-distribute any updated resources to other nodes every 2 minutes"
    echo "*/2 * * * * root /srv/cray/scripts/common/distribute.sh >> /var/log/cray/cron.log 2>&1" > /etc/cron.d/cray-k8s-distribute

    check_master_taint
    add-oidc-cronjob
    add-etcd-defrag-cron

    echo "Setting up job for kicking k8s cronjobs when they stop getting scheduled."
    cp /srv/cray/resources/common/cronjob_kicker.py /usr/bin/cronjob_kicker.py
    chmod 0755 /usr/bin/cronjob_kicker.py
    echo "0 */2 * * * root KUBECONFIG=/etc/kubernetes/admin.conf /usr/bin/cronjob_kicker.py" > /etc/cron.d/cronjob-kicker

    echo "Create secret for Prometheus to scrape etcd."
    kubectl -n sysmgmt-health create secret generic etcd-client-cert --from-file=etcd-client=/etc/kubernetes/pki/apiserver-etcd-client.crt --from-file=etcd-client-key=/etc/kubernetes/pki/apiserver-etcd-client.key --from-file=etcd-ca=/etc/kubernetes/pki/etcd/ca.crt --save-config --dry-run -o yaml | kubectl apply -f -

    reconfigure-kube-api-server
    reconfigure-kube-scheduler
    reconfigure-kube-controller
    reconfigure_coredns
    add_pod_priority_class
    populate-tenant-admin-conf
    complete-initialization
    /srv/cray/scripts/common/prep-for-etcd-backup.sh ${BACKUP_ENDPOINTS_FOR_ETCD} ${RGW_VIRTUAL_IP}
  elif [[ "$node_type" == "worker" ]]; then
    get-kube-config
    set_conntrack_liberal
    complete-initialization
  fi
}

function complete-initialization() {
  restart-daemons
  get-ceph-config $FIRST_STORAGE_HOSTNAME
  configure-csm-share
  configure-s3fs
  add_kata_configuration
  mark-initialized
}

function populate-tenant-admin-conf () {
  echo "Creating /etc/kubernetes/tenant-admin.conf file."
  export CA_CRT=$(cat /etc/kubernetes/pki/ca.crt | base64 -w0)
  envsubst < /srv/cray/resources/common/tenant-admin.conf > /etc/kubernetes/tenant-admin.conf
}

function reconfigure-kube-controller() {
  echo "In reconfigure-kube-controller()"

  #
  # This enables prometheus monitoring of the kube controller
  #
  sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-controller-manager.yaml

  echo "Sleeping 30 seconds after reconfiguring kube controller to let things settle.."
  sleep 30
}

function reconfigure-kube-scheduler() {
  echo "In reconfigure-kube-scheduler()"

  #
  # This enables prometheus monitoring of the scheduler
  #
  sed -i '/--port=0/d' /etc/kubernetes/manifests/kube-scheduler.yaml
  sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-scheduler.yaml

  echo "Sleeping 30 seconds after reconfiguring kube scheduler to let things settle.."
  sleep 30
}

function reconfigure-kube-api-server() {
  echo "In reconfigure-kube-api-server()"
  # TODO: local audit_logging_enabled=$(craysys metadata get k8s-api-auditing-enabled)
  local audit_logging_enabled="false"
  echo "Audit logging enabled: $audit_logging_enabled"

  if [[ "$audit_logging_enabled" == "true" ]]; then
    echo "Enabling Kubernetes API audit logging."
    mkdir -p /etc/kubernetes/audit
    chmod 0700 /etc/kubernetes/audit
    cp /srv/cray/resources/common/kubernetes_api_audit/audit-policy.yaml /etc/kubernetes/audit/
    chmod 0600 /etc/kubernetes/audit/audit-policy.yaml
    /usr/bin/python3 /srv/cray/resources/common/kubernetes_api_audit/update_api_manifest.py
  else
    echo "Kubernetes API audit logging is disabled by configuration."
  fi

  echo "Enabling PodSecurityPolicy"
  mkdir -p /etc/kubernetes/enable_psp
  chmod 0700 /etc/kubernetes/enable_psp
  cp /srv/cray/resources/common/enable_psp/enable_psp.py /etc/kubernetes/enable_psp/
  /usr/bin/python3 /srv/cray/resources/common/enable_psp/enable_psp.py

  echo "Sleeping 30 seconds after reconfiguring api server to let things settle.."
  sleep 30
}

function get-ceph-config() {
  echo "In get-ceph-config()"
  storage_node=$1
  ceph_files="/etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring"

  if [[ "$(hostname)" =~ ^ncn-w ]]; then
    ceph_files="/etc/ceph/ceph.conf"
  fi

  cnt=0
  until /usr/sbin/fping -c 1 $storage_node &>/dev/null
  do
    echo "Waiting for $storage_node to be pingable..."
    sleep 5
    cnt=$((cnt+1))
    if [ "$cnt" -eq 120 ]; then
      echo "ERROR: Giving up on waiting for $storage_node to be pingable..."
      exit 1
    fi
  done
  for ceph_file in $ceph_files
  do
    cnt=0
    until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $storage_node ls $ceph_file > /dev/null 2>&1
    do
      echo "Waiting for $storage_node to have $ceph_file present..."
      sleep 5
      cnt=$((cnt+1))
      if [ "$cnt" -eq 120 ]; then
        echo "ERROR: Giving up on waiting for $storage_node to have $ceph_file present..."
        exit 1
      fi
    done
    (scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $storage_node:$ceph_file $ceph_file && echo "Successfully retrieved $ceph_file") || echo "Failed to retrieve $ceph_file"
 done
}

function configure-external-etcd() {
  echo "In configure-external-etcd()"
  mkdir -p /etc/kubernetes/pki/etcd

  echo "Generating etcd configuration and services files"
  envsubst < /srv/cray/resources/etcd/kubeadmcfg.yaml > /etc/kubernetes/kubeadmcfg.yaml
  envsubst < /srv/cray/resources/etcd/etcd-node-ca-csr.json > /etc/kubernetes/etcd-node-ca-csr.json
  envsubst < /srv/cray/resources/etcd/etcd.service > /etc/systemd/system/etcd.service

  if [[ "$(hostname)" == $FIRST_MASTER_HOSTNAME ]] || [[ "$(hostname)" =~ ^$FIRST_MASTER_HOSTNAME-.* ]]; then
    echo "Generating the kubeadm certificate authority"
    kubeadm init phase certs etcd-ca --kubernetes-version="v${KUBERNETES_PULL_VERSION}"
  else
    echo "Copying kubeadm certificate authority from first master"
    wait-for-remote-file "${FIRST_MASTER_HOSTNAME}:/etc/kubernetes/pki/etcd/ca.crt" "/etc/kubernetes/pki/etcd/ca.crt" "BEGIN CERTIFICATE" 10
    wait-for-remote-file "${FIRST_MASTER_HOSTNAME}:/etc/kubernetes/pki/etcd/ca.key" "/etc/kubernetes/pki/etcd/ca.key" "BEGIN RSA PRIVATE KEY" 10
  fi

  echo "Generating other kubernetes certs"
  kubeadm init phase certs etcd-server --config=/etc/kubernetes/kubeadmcfg.yaml
  kubeadm init phase certs etcd-peer --config=/etc/kubernetes/kubeadmcfg.yaml
  kubeadm init phase certs etcd-healthcheck-client --config=/etc/kubernetes/kubeadmcfg.yaml
  kubeadm init phase certs apiserver-etcd-client --config=/etc/kubernetes/kubeadmcfg.yaml

  echo "Determining if we are joining a new or existing etcd cluster"
  state=$(get-etcd-cluster-state)
  if [ "$state" == "existing" ]; then
    systemctl stop etcd.service
    member_dir=/var/lib/etcd/member
    member_dir_back=/var/tmp/member
    sed -i 's/new/existing/' /etc/systemd/system/etcd.service
    if [ -d "$member_dir" ]; then
      echo "Moving existing data in $member_dir to $member_dir_back"
      rm -rf $member_dir_back 2>&1
      mv -u $member_dir $member_dir_back 2>&1
    fi
    systemctl daemon-reload
  fi

  echo "Enabling and starting etcd service"
  systemctl enable etcd.service
  systemctl start etcd.service
}

function reconfigure_coredns() {

  echo "Applying resource limits and pod anti-affinity to coredns pods"
  while true; do
    pod_count=$(kubectl get pods -n kube-system | grep "^coredns-" | wc -l)
    if [ $pod_count -gt 0 ]; then
      echo "Coredns pods are created, continuing..."
      break
    fi
    sleep 5
    echo "Sleeping for five seconds waiting for coredns pods to start..."
  done

  cfile=/tmp/coredns-deployment.yaml
  kubectl -n kube-system get deployment coredns -o yaml > $cfile
  yq w -i $cfile 'spec.template.spec.containers.(name==coredns).resources.requests.cpu' '300m'
  yq w -i $cfile 'spec.template.spec.containers.(name==coredns).resources.requests.memory' '140Mi'
  yq w -i $cfile 'spec.template.spec.containers.(name==coredns).resources.limits.memory' '340Mi'
  yq m -i $cfile /srv/cray/resources/common/coredns-affinity.yaml
  kubectl apply -f $cfile
}

function add_pod_priority_class () {
  echo "Adding csm-high-priority-service pod priority class"
  cat > /tmp/csm-high-priority-service.yaml <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: csm-high-priority-service
value: 1000000
globalDefault: false
description: "This priority class should be used for CSM critical service pods only."
EOF
  kubectl apply -f /tmp/csm-high-priority-service.yaml
}

function add_kata_configuration () {
  echo "Attaching worker node with kata runtime label"

  if [[ "$(hostname)" =~ ^ncn-w ]]; then
      kubectl label node "$(hostname)" --overwrite katacontainers.io/kata-runtime=true
  else
      echo "Not a worker node. Skipping node labelling"
  fi
 
  cat > /tmp/qemu-class.yaml <<EOF
---
kind: RuntimeClass
apiVersion: node.k8s.io/v1
metadata:
    name: kata-qemu
handler: kata-qemu
overhead:
    podFixed:
        memory: "160Mi"
        cpu: "250m"
scheduling:
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
EOF
  echo "Installing kata-qemu runtime class onto kubernetes"

  kubectl apply -f /tmp/qemu-class.yaml 
}

if [ -f "$initialized_file" ]; then
  echo "This Kubernetes node has been initialized"
  exit 0
fi
echo 'source <(kubectl completion bash)' >>~/.bashrc
pre-configure-node

echo "Setting up weave and multus containerd config files"
mkdir -p /etc/cni/net.d/multus.d
envsubst < /srv/cray/resources/containerd/10-weave.conflist > /etc/cni/net.d/10-weave.conflist

echo "Populating /etc/cni/net.d/00-multus.conf file"
if [ "${K8S_CNI}" == "cilium" ]; then
  export MULTUS_CONF=$(cat /srv/cray/resources/multus/multus-cilium.conf)
else
  export MULTUS_CONF=$(cat /srv/cray/resources/multus/multus-weave.conf)
fi

echo "{
${MULTUS_CONF}
}" > /etc/cni/net.d/00-multus.conf

echo "Ensuring our containerd config is in place and restarting containerd to pick up the changes"
envsubst < /srv/cray/resources/containerd/config.toml > /etc/containerd/config.toml
systemctl restart containerd

echo "Handling custom kubelet configuration"
echo "Setting extra kubelet args"
cat > /etc/sysconfig/kubelet <<EOF
KUBELET_EXTRA_ARGS="${KUBELET_EXTRA_ARGS} --container-runtime=remote --runtime-request-timeout=15m --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

echo "Waiting for ${CONTROL_PLANE_HOSTNAME} to be available..."
# TODO:
#while host $CONTROL_PLANE_HOSTNAME | grep 'NXDOMAIN' &>/dev/null; do
#  sleep 5
#done

if [[ "$(hostname)" == $FIRST_MASTER_HOSTNAME ]] || [[ "$(hostname)" =~ ^$FIRST_MASTER_HOSTNAME-.* ]]; then
  # TODO: export PODS_CIDR=$(craysys metadata get kubernetes-pods-cidr)
  export PODS_CIDR="10.32.0.0/12"
  # TODO: export SERVICES_CIDR=$(craysys metadata get kubernetes-services-cidr)
  export SERVICES_CIDR="10.16.0.0/12"
  # TODO: export MAX_PODS_PER_NODE=$(craysys metadata get kubernetes-max-pods-per-node)
  export MAX_PODS_PER_NODE="200"
  # TODO: export WEAVE_MTU=$(craysys metadata get kubernetes-weave-mtu)
  export WEAVE_MTU="1376"
  configure-external-etcd
  kubeadm certs certificate-key > /etc/cray/kubernetes/certificate-key
  chmod 0600 /etc/cray/kubernetes/certificate-key
  export CERTIFICATE_KEY=$(cat /etc/cray/kubernetes/certificate-key)

  configure-load-balancer-for-master

  setup-encryption

  envsubst < /srv/cray/resources/common/kubeadm.cfg > /etc/cray/kubernetes/kubeadm.yaml
  echo "Initializing Kubernetes on the first control plane node, pod cidr $PODS_CIDR, service cidr $SERVICES_CIDR"
  kubeadm init --config /etc/cray/kubernetes/kubeadm.yaml --upload-certs | tee /etc/cray/kubernetes/init-result

  post-kubeadm-init

  echo "Installing pod security policies"
  cp /srv/cray/resources/common/psp.yaml /etc/cray/kubernetes/psp.yaml
  cp /srv/cray/resources/common/psp-rbac.yaml /etc/cray/kubernetes/psp-rbac.yaml
  kubectl apply -f /etc/cray/kubernetes/psp.yaml
  kubectl apply -f /etc/cray/kubernetes/psp-rbac.yaml

  echo "Installing resource usage limits"
  namespaces="ceph-cephfs ceph-rbd loftsman metallb-system sma ims backups istio-system sysmgmt-health velero"
  for namespace in $namespaces; do
    export RESOURCE_LIMITS_NAMESPACE="$namespace"
    envsubst < /srv/cray/resources/common/resource-limits.yaml > "/etc/cray/kubernetes/resource-limits-${namespace}.yaml"
    kubectl apply -f /etc/cray/kubernetes/resource-limits-${namespace}.yaml
  done
  export RESOURCE_LIMITS_NAMESPACE="default"
  envsubst < /srv/cray/resources/common/resource-limits-requests.yaml > /etc/cray/kubernetes/resource-limits-requests-default.yaml
  kubectl apply -f /etc/cray/kubernetes/resource-limits-requests-default.yaml
  unset RESOURCE_LIMITS_NAMESPACE

  # If we are installing Cilium, then we can install it before post-join
  if [ "${K8S_CNI}" == "cilium" ]; then
    echo "Applying the network manifests"
    /srv/cray/scripts/common/apply-networking-manifests.sh
  fi

  post-join first-master

  if [ "${K8S_CNI}" != "cilium" ]; then
    # Wait for a quorum of nodes to join before applying the network manifests
    # TODO: exp_node_count=$(craysys metadata get host-records | jq '.[] | .aliases | .[]' | grep "ncn-[mw].*nmn" | wc -l)
    exp_node_count="2"

    if [ $exp_node_count -le 0 ]; then
      echo "ERROR: Failed to find expected number of nodes"
      exit 1
    fi

    # subtract 1 from the expected count for m001 which won't be joining yet
    quorum_count=$(( (exp_node_count - 1)/2 + 1 ))

    node_count=$(kubectl get nodes --no-headers=true | wc -l)
    net_config_applied=false

    echo "Waiting for $quorum_count nodes to join before applying network manifests"

    # Wait 20 minutes for the nodes to join
    for i in $(seq 1 240); do
      echo "$node_count nodes have joined"
      if [ $node_count -ge $quorum_count ]; then
        echo "Applying the network manifests"
        /srv/cray/scripts/common/apply-networking-manifests.sh
        net_config_applied=true
        break
      fi
      sleep 5
      node_count=$(kubectl get nodes --no-headers=true | wc -l)
    done

    if ! $net_config_applied; then
      echo "ERROR: Timed out waiting for $quorum_count nodes to join"
      exit 1
    fi
  fi

  exit 0
fi

sleep_seconds="$[ ( $RANDOM % 10 ) ]"
echo "Sleeping a random amount of seconds (${sleep_seconds}) to stagger join operations a bit"
sleep ${sleep_seconds}s

if [[ "$(hostname)" =~ ^ncn-m ]]; then
  configure-external-etcd
  join "/etc/cray/kubernetes/join-command-control-plane"
  post-join master
  exit 0
else
  join "/etc/cray/kubernetes/join-command"
  post-join worker
  exit 0
fi
