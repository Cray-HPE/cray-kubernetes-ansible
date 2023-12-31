#!/bin/bash

export KUBECONFIG=/etc/kubernetes/admin.conf

if kubectl get secret -n istio-system ingress-gateway-cert > /dev/null 2>&1 ; then
  kubectl get secret -n istio-system ingress-gateway-cert -o json | jq -r '.data."ca.crt"' | base64 -d > /tmp/oidc.pem
  fs_sha=$(shasum /etc/kubernetes/pki/oidc.pem | awk '{print $1}')
  k8s_sha=$(shasum /tmp/oidc.pem | awk '{print $1}')
  if [ "$k8s_sha" != "$fs_sha" ]; then
    echo "Detected outdated or missing oidc.pem file -- refreshing with ingress-gateway-cert secret contents..."
    mv /tmp/oidc.pem /etc/kubernetes/pki/oidc.pem
  else
    rm /tmp/oidc.pem
  fi
fi
