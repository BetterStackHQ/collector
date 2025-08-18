#!/bin/bash

set -euo pipefail

NAMESPACE="kube-system"
DAEMONSET="cilium"
PRIORITY=1

echo "Finding Cilium pods..."
PODS=$(kubectl -n $NAMESPACE get pods -l k8s-app=$DAEMONSET -o jsonpath='{.items[*].metadata.name}')

for POD in $PODS; do
  echo "Cleaning up on pod: $POD"
  kubectl -n $NAMESPACE exec "$POD" -- bash -c "
    for IFACE in \$(ls /sys/class/net); do
      # Skip loopback
      if [[ \"\$IFACE\" == \"lo\" ]]; then continue; fi
      echo \"  Checking interface: \$IFACE\"
      if tc filter show dev \$IFACE ingress 2>/dev/null | grep -q 'priority $PRIORITY'; then
        echo '    Deleting ingress filter priority $PRIORITY on' \$IFACE
        tc filter del dev \$IFACE ingress priority $PRIORITY || true
      fi
      if tc filter show dev \$IFACE egress 2>/dev/null | grep -q 'priority $PRIORITY'; then
        echo '    Deleting egress filter priority $PRIORITY on' \$IFACE
        tc filter del dev \$IFACE egress priority $PRIORITY || true
      fi
    done
  "
done

echo "Setting Cilium BPF filter priority to 2 in ConfigMap..."
kubectl -n $NAMESPACE patch configmap cilium-config --type merge -p '{"data":{"bpf-filter-priority":"2"}}'

echo "Restarting Cilium DaemonSet..."
kubectl -n $NAMESPACE rollout restart daemonset/$DAEMONSET

echo "Waiting for rollout to complete..."
kubectl -n $NAMESPACE rollout status daemonset/$DAEMONSET

echo "Configuration update complete."

