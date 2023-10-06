#!/bin/bash

function check-s3fs-mounts {
  s3fs_mounts=$(cat /etc/fstab | grep fuse.s3fs | awk '{print $2}')

  for mount in $s3fs_mounts; do
    if ! mount | grep -q $mount; then
      echo "fstab entry for $mount is unmounted, re-mounting."
      mount $mount
      if [ $? -ne 0 ]; then
         echo "Failed to mount: $mount."
      fi
    fi
  done
}

function check-cephfs-mounts {
  output=$(cat /etc/fstab | grep -v '^#' | grep -q "/etc/cray/upgrade/csm ceph")

  if [[ "$?" -eq 0 ]] ; then
    if ! mountpoint -q /etc/cray/upgrade/csm; then
      if [[ $(ceph orch ps --daemon_type mds --service_name mds.admin-tools -f json-pretty | jq -r '. | map(select(.daemon_name)) | length' 2>/dev/null) -lt 3 ]]; then
        #
        # Cephfs isn't healthy, we'll try again laster
        #
        exit 0
      fi
      echo "CSM share not currently mounted, attempting to mount..."
      mount /etc/cray/upgrade/csm
    fi
  else
    #
    # No entry in fstab -- we'll do nothing in case
    # an admin has commented out or removed from fstab.
    #
    exit 0
  fi
}

check-s3fs-mounts
check-cephfs-mounts
