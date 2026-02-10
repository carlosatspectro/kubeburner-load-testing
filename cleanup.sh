#!/bin/sh
# Idempotent cleanup of noisy-neighbor leftovers (failed runs, old RBAC, PVC).
# Usage: cleanup.sh [NAMESPACE] [FIO_PVC_NAME]
# Defaults: NAMESPACE=noisy-neighbor, FIO_PVC_NAME=noisy-neighbor-fio
set -eu

LABEL_PART_OF="${LABEL_PART_OF:-app.kubernetes.io/part-of=noisy-neighbor}"

NAMESPACE="${1:-noisy-neighbor}"
FIO_PVC_NAME="${2:-noisy-neighbor-fio}"

say() { printf '\n==> %s\n' "$*"; }

# Cluster-scoped RBAC (must be deleted before namespace-scoped so bindings go first)
say "Deleting ClusterRoleBinding and ClusterRole with label $LABEL_PART_OF"
kubectl delete clusterrolebinding -l "$LABEL_PART_OF" --ignore-not-found=true
kubectl delete clusterrole -l "$LABEL_PART_OF" --ignore-not-found=true

# Namespace may not exist
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  say "Namespace $NAMESPACE not found; skipping namespaced cleanup."
  exit 0
fi

# Workloads: deployments, jobs, pods (and any other workload types with the label)
say "Deleting deployments, jobs, pods in $NAMESPACE with label $LABEL_PART_OF"
kubectl -n "$NAMESPACE" delete deployment,job,pod -l "$LABEL_PART_OF" --ignore-not-found=true

# PVC by name (FIO_PVC_NAME)
say "Deleting PVC $FIO_PVC_NAME in $NAMESPACE"
kubectl -n "$NAMESPACE" delete pvc "$FIO_PVC_NAME" --ignore-not-found=true

# Namespaced RBAC: ServiceAccount, Role, RoleBinding
say "Deleting ServiceAccount, Role, RoleBinding in $NAMESPACE with label $LABEL_PART_OF"
kubectl -n "$NAMESPACE" delete serviceaccount,role,rolebinding -l "$LABEL_PART_OF" --ignore-not-found=true

say "Cleanup complete."
