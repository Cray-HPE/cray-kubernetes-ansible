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

ip=$(dig +short $(hostname).nmn)
cnt=0

while [ "$ip" == "" ]; do
  cnt=$((cnt+1))
  ip=$(dig +short $(hostname).nmn)
  echo "Waiting for resolution of $(hostname)"
  # TODO:
  continue
  sleep 1
  if [ "$cnt" -eq 60 ]; then
    echo "ERROR: Giving up on DNS resolution..."
    exit 1
  fi
done

export NETWORK_DAEMONS=""
# TODO: export RGW_VIRTUAL_IP="http://$(craysys metadata get rgw-virtual-ip)"
export RGW_VIRTUAL_IP="10.252.1.3"
export CONTROLLER_MANAGER_EXTRA_ARGS="{'flex-volume-plugin-dir': '/etc/cray/kubernetes/flexvolume'}"
# TODO: export CONTROL_PLANE_HOSTNAME="$(craysys metadata get k8s_virtual_ip)"
export CONTROL_PLANE_HOSTNAME="10.252.1.2"
echo "CONTROL_PLANE_HOSTNAME has been set to $CONTROL_PLANE_HOSTNAME"
export CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_HOSTNAME}:6442"
echo "CONTROL_PLANE_ENDPOINT has been set to $CONTROL_PLANE_ENDPOINT"
export K8S_NODE_IP="$(dig +short $(hostname).nmn)"
echo "Setting K8S_NODE_IP to ${K8S_NODE_IP} for KUBELET_EXTRA_ARGS and kubeadm config"
export KUBELET_EXTRA_ARGS="--node-ip ${K8S_NODE_IP}"
# TODO: export FIRST_MASTER_HOSTNAME=$(craysys metadata get first_master_hostname)
export FIRST_MASTER_HOSTNAME="kubernetes"
echo "FIRST_MASTER_HOSTNAME has been set to $FIRST_MASTER_HOSTNAME"
export IMAGE_REGISTRY="docker.io"
echo "IMAGE_REGISTRY has been set to $IMAGE_REGISTRY"
export FIRST_STORAGE_HOSTNAME=ncn-s001.nmn
export ETCD_HOSTNAME=$(hostname)
export ETCD_HA_PORT=2381
export API_GW=api-gw-service-nmn.local
echo "API_GW has been set to $API_GW"
logfile=/var/log/cloud-init-output.log

function get_ip_from_metadata() {
  host=$1
  ip=$(cloud-init query ds | jq -r ".meta_data[].host_records[] | select(.aliases[]? == \"$host\") | .ip" 2>/dev/null)
  echo $ip
}

function pre-configure-node() {
  echo "In pre-configure-node()"

  echo "Copying /etc/ssl/ca-bundle.pem to /etc/kubernetes/pki/oidc.pem for kube-apiserver"
  mkdir -pv /etc/kubernetes/pki
  cp /etc/ssl/ca-bundle.pem /etc/kubernetes/pki/oidc.pem

  return 0
}

function configure-load-balancer-for-master() {
  echo "In configure-load-balancer-for-master()"

  if [[ "$(hostname)" =~ ^ncn-m ]]; then
    echo "Configuring haproxy and keepalived"
    /srv/cray/scripts/metal/generate_haproxy_cfg.sh > /etc/haproxy/haproxy.cfg
    /srv/cray/scripts/metal/generate_keepalived_conf.sh > /etc/keepalived/keepalived.conf

    for service in haproxy keepalived; do
      systemctl enable $service
      systemctl start $service
    done
  fi
}

function post-kubeadm-init() {
  echo "In post-kubeadm-init()"
}

function get-etcd-initial-cluster-members() {
  result=""
  for x in `seq 5`
  do
    host_name="ncn-m00$x.nmn"
    host_name_short="ncn-m00$x"
    ip=$(get_ip_from_metadata $host_name)
    if [ "$ip" != "" ]; then
      result+="${host_name_short}=https://${ip}:2380,"
    fi
  done
  #
  # Strip off final comma
  #
  echo $result | sed 's/.$//'
}

function get-etcdctl-backup-endpoints() {
  result=""
  for x in `seq 5`
  do
    host_name="ncn-m00$x.nmn"
    ip=$(get_ip_from_metadata $host_name)
    if [ "$ip" != "" ]; then
      result+="${ip}:2379,"
    fi
  done
  #
  # Strip off final comma
  #
  echo $result | sed 's/.$//'
}

function is_disk_wiped() {
  grep 'metal.no-wipe=0' -q /proc/cmdline
  echo $?
}

function get-etcd-cluster-state() {
  disk_wiped=$(is_disk_wiped)
  my_name=$(hostname)
  my_ip=$(get_ip_from_metadata ${my_name}.nmn)
  talked_to_cluster="false"
  for x in `seq 5`
  do
    host_name="ncn-m00$x.nmn"
    host_name_short="ncn-m00$x"
    ip=$(get_ip_from_metadata $host_name)
    if [ "$ip" != "" ]; then
      if [ "$my_ip" != "$ip" ]; then
        member_list=$(etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/ca.crt  --key=/etc/kubernetes/pki/etcd/ca.key --endpoints=https://${ip}:2379 member list 2>> $logfile)
        rc=$?
        if [ "$rc" -eq 0 ]; then
          echo "Successfully reached https://${ip}:2379 endpoint to get member list" >> $logfile
          talked_to_cluster="true"
          #
          # We are communicating with another healthy master, if disk is being
          # wiped on the local system, then we'll remove/re-add this etcd member.
          #
          if [ "$disk_wiped" -eq 0 ]; then
            echo "This disk has been wiped, removing this node from the etcd cluster if present" >> $logfile
            my_member_id=$(etcdctl --hex=true --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/ca.crt  --key=/etc/kubernetes/pki/etcd/ca.key --endpoints=https://${ip}:2379 member list -w table | grep -e $my_name -e $my_ip | awk '{print $2}' 2>> $logfile )
            if [ ! -z $my_member_id ]; then
               echo "Found member id $my_member_id for this host, removing from the cluster." >> $logfile
               etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/ca.crt  --key=/etc/kubernetes/pki/etcd/ca.key --endpoints=https://${ip}:2379 member remove ${my_member_id} 2>&1 >> $logfile
            fi
            echo "Adding https://${my_ip}:2380 for ${my_name} to the cluster" >> $logfile
            etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/ca.crt  --key=/etc/kubernetes/pki/etcd/ca.key --endpoints=https://${ip}:2379 member add $my_name --peer-urls https://${my_ip}:2380 2>&1 >> $logfile
            echo "existing"
          else
            #
            # We talked to other members, but we're not wiping the disk,
            # so no member changes needed.
            #
            echo "new"
          fi
          return
        fi
      fi
    fi
  done
  if [ $talked_to_cluster == "false" ]; then
    #
    # We were unable to talk to any existing members of the cluster,
    # so presuming this is a fresh install/new cluster.
    #
    echo "Unable to determine etcd cluster membership, assuming this is a newly forming cluster..." >> $logfile
    echo "new"
  fi
}

function expand-root-disk() {
  echo "In expand-root-disk() -- skipping since we're on metal"
}

function configure-s3fs-directory() {

  local s3_configure_arg_count=$#
  local s3_user=$1
  local s3_bucket=$2
  local s3fs_mount_dir=$3
  if [[ $s3_configure_arg_count -eq 5 ]]; then
    #s3fs_cache_dir and s3fs_opts were passed as args
    local s3fs_cache_dir=$4
    local s3fs_opts=$5
  elif [[ $s3_configure_arg_count -eq 4 ]]; then
    #s3fs_cache_dir was not passed, meaning no cache desired  
    local s3fs_opts=$4
  fi

  echo "Configuring for ${s3_bucket} S3 bucket at ${s3fs_mount_dir} for ${s3_user} S3 user"

  mkdir -p ${s3fs_mount_dir}

  local pwd_file=/root/.${s3_user}.s3fs
  local access_key=$(kubectl get secret ${s3_user}-s3-credentials -o json | jq -r '.data.access_key' | base64 -d)
  local secret_key=$(kubectl get secret ${s3_user}-s3-credentials -o json | jq -r '.data.secret_key' | base64 -d)
  local s3_endpoint=$(kubectl get secret ${s3_user}-s3-credentials -o json | jq -r '.data.http_s3_endpoint' | base64 -d)

  echo "${access_key}:${secret_key}" > ${pwd_file}
  chmod 600 ${pwd_file}

  if ! mount | grep -q ^s3fs.*${s3fs_mount_dir}; then
    s3fs ${s3_bucket} ${s3fs_mount_dir} -o passwd_file=${pwd_file},url=${s3_endpoint},${s3fs_opts}
  fi

  if ! grep -q ^${s3_bucket} /etc/fstab; then
    echo "Adding fstab entry for ${s3_bucket} S3 bucket at ${s3fs_mount_dir} for ${s3_user} S3 user"
    echo "${s3_bucket} ${s3fs_mount_dir} fuse.s3fs _netdev,allow_other,passwd_file=${pwd_file},url=${s3_endpoint},${s3fs_opts} 0 0" >> /etc/fstab
  fi
}

function configure-s3fs() {
  echo "In configure-s3fs()"

  until kubectl get cm ceph-csi-config > /dev/null 2>&1
  do
    echo "Waiting for storage node to complete rgw configuration (waiting for ceph-csi-config configmap)..."
    sleep 5
  done

  s3fs_cache_dir=/var/lib/s3fs_cache

  if [ -d ${s3fs_cache_dir} ]; then
    s3fs_opts="use_path_request_style,use_cache=${s3fs_cache_dir},check_cache_dir_exist,use_xattr"
   else
    s3fs_opts="use_path_request_style,use_xattr"
  fi

  if [[ "$(hostname)" =~ ^ncn-m ]]; then
    sdu_opts="uid=2370,gid=2370,umask=0007,allow_other"
    configure-s3fs-directory sds sds /var/opt/cray/sdu/collection-mount ${s3fs_cache_dir} "${s3fs_opts},${sdu_opts}"
    #
    # Set cache pruning for sdu to 100G (50%) of the 200G volume (five minutes after midnight)
    #
    echo "5 0 * * * root /usr/bin/prune-s3fs-cache.sh sds ${s3fs_cache_dir} 107374182400 -silent" > /etc/cron.d/prune-s3fs-sds-cache

    configure-s3fs-directory config-data config-data /var/opt/cray/config-data use_path_request_style,use_xattr
    #
    # No cache pruning required for config-data folder as we are not caching this folder

  else
    configure-s3fs-directory ims boot-images /var/lib/cps-local/boot-images ${s3fs_cache_dir} ${s3fs_opts}
    #
    # Set cache pruning for boot-images to 150G (75%) of the 200G volume
    #
    echo "0 0 * * * root /usr/bin/prune-s3fs-cache.sh boot-images ${s3fs_cache_dir} 161061273600 -silent" > /etc/cron.d/prune-s3fs-boot-images-cache
  fi

  #
  # Add cronjob on masters and workers to check and remount s3fs and cephfs
  # mountpoints.
  #
  echo "* * * * * root /usr/bin/ensure-ceph-mounts.sh" > /etc/cron.d/ensure-ceph-mounts
}

function configure-csm-share() {
  echo "In configure-csm-share function.."

  if [[ "$(hostname)" =~ "ncn-m002" ]]; then
  until [ -f /etc/ceph/ceph.client.admin.keyring ]
    do
      echo "Waiting for ceph admin credentials"
      sleep 10
    done
  
    until [[ $(ceph orch ps --daemon_type mds -f json-pretty | jq -r '. | map(select(.daemon_name)) | length' 2>/dev/null) -ge 3 ]]
    do
       echo "Waiting for Ceph fs to be ready"
       sleep 60
    done
  echo "Ceph fs is reporting ready.  Creating Ceph fs share."
  fi

  if [[ "$(hostname)" =~ "ncn-m002" ]]; then
    echo "Creating admin-tools ceph fs share"
    if [[ "$(ceph fs status admin-tools --format json-pretty|jq -r .clients[].fs)" != "admin-tools" ]]; then
      ceph config generate-minimal-conf > /etc/ceph/new_ceph.conf
      cp /etc/ceph/new_ceph.conf /etc/ceph/ceph.conf
      rm /etc/ceph/new_ceph.conf
      ceph fs volume create admin-tools --placement="3 ncn-s001 ncn-s002 ncn-s003"
      echo "Creating admin-tools keyring"
      ceph fs authorize admin-tools client.admin-tools / rw
    fi
    ceph auth export client.admin-tools -o /etc/ceph/ceph.client.admin-tools.keyring
  elif [[ "$(hostname)" =~ ("ncn-m"|"ncn-w") ]]; then
    until [ -f /etc/ceph/ceph.client.admin-tools.keyring ]
    do
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ncn-m002:/etc/ceph/ceph.client.admin-tools.keyring /etc/ceph/ceph.client.admin-tools.keyring 2>/dev/null||true
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ncn-m002:/etc/ceph/ceph.conf /etc/ceph/ceph.conf 2>/dev/null||true
      if [ ! -f /etc/ceph/ceph.client.admin-tools.keyring ]; then
        echo "Waiting for the admin-tools keyring"
        sleep 60
      fi
    done
  fi

  echo "Updating fstab"
  if ! grep "admin-tools@.admin-tools" /etc/fstab > /dev/null; then
    echo "admin-tools@.admin-tools=/ /etc/cray/upgrade/csm ceph" >> /etc/fstab
  fi
  mkdir -p /etc/cray/upgrade/csm
  if [[ "$(hostname)" =~ "ncn-m002" ]]; then
    until [[ $(ceph orch ps --daemon_type mds --service_name mds.admin-tools -f json-pretty | jq -r '. | map(select(.daemon_name)) | length' 2>/dev/null) -ge 3 ]]; do
      echo "Waiting for Ceph fs to be ready"
      sleep 60
    done
  fi
  if ! mountpoint -q /etc/cray/upgrade/csm; then
    echo "Mounting CSM share"
    mount /etc/cray/upgrade/csm
    if [ "$?" -ne 0 ]; then
      echo "ERROR: CSM share (/etc/cray/upgrade/csm) failed to mount."
      exit 1
    fi
  else
    echo "CSM share is mounted."
  fi
}
