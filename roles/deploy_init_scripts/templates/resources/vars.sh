#!/bin/bash
#
# MIT License
#
# (C) Copyright 2022 Hewlett Packard Enterprise Development LP
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
#
# Common file that can be sourced and then used by both
# build and runtime scripts.
#
# Keep versions in sync with https://github.com/Cray-HPE/csm docker/index.yaml
export KUBERNETES_PULL_PREVIOUS_VERSION="1.21.12"
export KUBERNETES_PULL_VERSION="$(rpm -q --queryformat '%{VERSION}' kubeadm | awk -F '.' '{print $1"."$2"."$3}')"
export WEAVE_VERSION="2.8.1"
export WEAVE_PREVIOUS_VERSION="2.8.0"
export CILIUM_CLI_VERSION="v0.15.7"
export CILIUM_CNI_VERSION="v1.14.1"
export CILIUM_HUBBLE_VERSION="v0.12.0"
export CILIUM_TETRAGON_VERSION="v0.11.0"
export MULTUS_VERSION="v3.9.3"
export MULTUS_PREVIOUS_VERSION="v3.9.1"
export CONTAINERD_VERSION="1.5.16"
export VELERO_VERSION="v1.6.3"
export ETCD_VERSION="v3.5.0"
export KATA_VERSION="3.2.0-rc0"
#
# https://github.com/coredns/deployment/blob/master/kubernetes/CoreDNS-k8s_version.md
#
export COREDNS_PREVIOUS_VERSION="1.8.0"
export COREDNS_VERSION="v1.8.4"

# Note from k8s 1.20...ish and 1.22 the pause container changed versions
export PAUSE_PREVIOUS_VERSION="3.4.1"
export PAUSE_VERSION="3.5"

# adding troubleshooting echo
echo "COREDNS_VERSION=$COREDNS_VERSION"
