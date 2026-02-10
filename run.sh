#!/bin/sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
config_path="$script_dir/config.yaml"
workload_path="$script_dir/workloads/noisy-neighbor.yaml"
probe_rbac_template="$script_dir/manifests/probe-rbac.yaml"
fio_cleanup_rbac_template="$script_dir/manifests/fio-cleanup-rbac.yaml"
fio_pvc_template="$script_dir/manifests/fio-pvc.yaml"

if [ ! -f "$config_path" ]; then
  echo "config.yaml not found at $config_path" >&2
  exit 1
fi

if [ ! -f "$workload_path" ]; then
  echo "workload file not found at $workload_path" >&2
  exit 1
fi

if [ ! -f "$probe_rbac_template" ]; then
  echo "probe RBAC manifest not found at $probe_rbac_template" >&2
  exit 1
fi

if [ ! -f "$fio_cleanup_rbac_template" ]; then
  echo "fio cleanup RBAC manifest not found at $fio_cleanup_rbac_template" >&2
  exit 1
fi

if [ ! -f "$fio_pvc_template" ]; then
  echo "fio PVC manifest not found at $fio_pvc_template" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (v4.52.4 recommended). Please install yq and retry." >&2
  exit 1
fi

is_true() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_config() {
  yq -r ".$1 // \"\"" "$config_path"
}

set_yaml_value() {
  path_expr="$1"
  value="$2"
  force_string="${3:-false}"

  if [ -z "$value" ]; then
    return 0
  fi

  if [ "$force_string" = "true" ]; then
    VALUE="$value" yq -i "$path_expr = strenv(VALUE)" "$rendered_file"
    return 0
  fi

  case "$value" in
    *[!0-9]*)
      VALUE="$value" yq -i "$path_expr = strenv(VALUE)" "$rendered_file"
      ;;
    *)
      VALUE="$value" yq -i "$path_expr = (env(VALUE) | tonumber)" "$rendered_file"
      ;;
  esac
}

set_object_inputvar() {
  job="$1"
  template="$2"
  key="$3"
  value="$4"
  force_string="${5:-false}"

  set_yaml_value "(.jobs[] | select(.name==\"${job}\") | .objects[] | select(.objectTemplate==\"${template}\") | .inputVars.${key})" "$value" "$force_string"
}

set_ramp_inputvar() {
  template="$1"
  key="$2"
  value="$3"
  force_string="${4:-false}"

  set_yaml_value "(.jobs[] | select(.name | test(\"^ramp-step-[0-9]+$\")) | .objects[] | select(.objectTemplate==\"${template}\") | .inputVars.${key})" "$value" "$force_string"
}

cleanup_existing_namespaced_resources() {
  if kubectl get namespace "$namespace_value" >/dev/null 2>&1; then
    kubectl -n "$namespace_value" delete deployment,job -l app.kubernetes.io/part-of=noisy-neighbor --ignore-not-found=true
  fi
}

expand_ramp_steps() {
  steps="$1"
  if ! yq -e '.jobs[] | select(.name=="baseline-probes")' "$rendered_file" >/dev/null 2>&1 || \
     ! yq -e '.jobs[] | select(.name=="ramp-step-1")' "$rendered_file" >/dev/null 2>&1 || \
     ! yq -e '.jobs[] | select(.name=="recovery-probes")' "$rendered_file" >/dev/null 2>&1 || \
     ! yq -e '.jobs[] | select(.name=="fio-pvc-cleanup")' "$rendered_file" >/dev/null 2>&1; then
    echo "workload must define baseline-probes, ramp-step-1, recovery-probes, and fio-pvc-cleanup jobs" >&2
    exit 1
  fi

  baseline_job="$(yq e '.jobs[] | select(.name=="baseline-probes")' "$rendered_file")"
  ramp_template_job="$(yq e '.jobs[] | select(.name=="ramp-step-1")' "$rendered_file")"
  recovery_job="$(yq e '.jobs[] | select(.name=="recovery-probes")' "$rendered_file")"
  cleanup_job="$(yq e '.jobs[] | select(.name=="fio-pvc-cleanup")' "$rendered_file")"

  yq -i '.jobs = []' "$rendered_file"
  BASELINE_JOB="$baseline_job" yq -i '.jobs += [(strenv(BASELINE_JOB) | from_yaml)]' "$rendered_file"

  step=1
  while [ "$step" -le "$steps" ]; do
    RAMP_TEMPLATE_JOB="$ramp_template_job" STEP="$step" yq -i '
      .jobs += [
        (
          strenv(RAMP_TEMPLATE_JOB) |
          from_yaml |
          .name = "ramp-step-" + strenv(STEP) |
          .jobIterations = 1 |
          (.objects[]? | select(has("inputVars")) | .inputVars.STEP) = (env(STEP) | tonumber) |
          (.objects[]? | select(.objectTemplate == "templates/probe-job.yaml" and has("inputVars")) | .inputVars.PROBE_PHASE) = "ramp-step-" + strenv(STEP)
        )
      ]
    ' "$rendered_file"
    step=$((step + 1))
  done

  RECOVERY_JOB="$recovery_job" yq -i '.jobs += [(strenv(RECOVERY_JOB) | from_yaml)]' "$rendered_file"
  CLEANUP_JOB="$cleanup_job" yq -i '.jobs += [(strenv(CLEANUP_JOB) | from_yaml)]' "$rendered_file"
}

kubeconfig_override="$(read_config KUBECONFIG)"
if [ -n "$kubeconfig_override" ]; then
  export KUBECONFIG="$kubeconfig_override"
fi

dry_run="${DRY_RUN:-false}"
print_rendered_path="${PRINT_RENDERED_PATH:-false}"

if ! is_true "$dry_run"; then
  if ! command -v kube-burner >/dev/null 2>&1; then
    echo "kube-burner is required and must be in PATH." >&2
    exit 1
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is required and must be in PATH." >&2
    exit 1
  fi
fi

rendered_file="$(mktemp /tmp/noisy-neighbor.rendered.XXXXXX)"
probe_rbac_rendered_file="$(mktemp /tmp/noisy-neighbor.probe-rbac.rendered.XXXXXX)"
fio_cleanup_rbac_rendered_file="$(mktemp /tmp/noisy-neighbor.fio-cleanup-rbac.rendered.XXXXXX)"
fio_pvc_rendered_file="$(mktemp /tmp/noisy-neighbor.fio-pvc.rendered.XXXXXX)"
cleanup_rendered="true"
cleanup() {
  if [ "$cleanup_rendered" = "true" ]; then
    rm -f "$rendered_file" "$probe_rbac_rendered_file" "$fio_cleanup_rbac_rendered_file" "$fio_pvc_rendered_file"
  fi
}
trap cleanup EXIT

cp "$workload_path" "$rendered_file"

namespace_value="$(read_config NAMESPACE)"
if [ -z "$namespace_value" ]; then
  namespace_value="noisy-neighbor"
fi

steps_value="$(read_config STEPS)"
if [ -z "$steps_value" ]; then
  steps_value="1"
fi
case "$steps_value" in
  *[!0-9]*|0)
    echo "STEPS must be a positive integer in config.yaml" >&2
    exit 1
    ;;
esac

namespace_escaped="$(printf '%s' "$namespace_value" | sed 's/[\\/&|]/\\\\&/g')"
sed "s|__NAMESPACE__|$namespace_escaped|g" "$probe_rbac_template" > "$probe_rbac_rendered_file"
sed "s|__NAMESPACE__|$namespace_escaped|g" "$fio_cleanup_rbac_template" > "$fio_cleanup_rbac_rendered_file"

set_yaml_value ".jobs[].namespace" "$namespace_value" true
set_yaml_value ".jobs[].objects[].inputVars.NAMESPACE" "$namespace_value" true

expand_ramp_steps "$steps_value"

probe_interval="$(read_config PROBE_INTERVAL)"
probe_timeout="$(read_config PROBE_TIMEOUT)"
baseline_duration="$(read_config BASELINE_DURATION)"
step_duration="$(read_config STEP_DURATION)"
recovery_duration="$(read_config RECOVERY_DURATION)"

set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_DURATION "$baseline_duration"
set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_INTERVAL "$probe_interval"
set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_TIMEOUT "$probe_timeout"

set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_DURATION)' "$step_duration"
set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_INTERVAL)' "$probe_interval"
set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_TIMEOUT)' "$probe_timeout"

set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_DURATION "$recovery_duration"
set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_INTERVAL "$probe_interval"
set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_TIMEOUT "$probe_timeout"

yq -i '.global.waitWhenFinished = false' "$rendered_file"
yq -i '
  (.jobs[] | select(.name=="baseline-probes" or .name=="recovery-probes" or (.name | test("^ramp-step-[0-9]+$")))) |= (
    .waitWhenFinished = true |
    .podWait = false |
    .verifyObjects = false |
    .jobPause = "0s" |
    .maxWaitTimeout = "10m"
  )
' "$rendered_file"
set_yaml_value '.jobs[].qps' "5"
set_yaml_value '.jobs[].burst' "10"

cpu_enabled="$(read_config CPU_ENABLED)"
cpu_replicas_step="$(read_config CPU_REPLICAS_STEP)"
cpu_workers="$(read_config CPU_WORKERS)"

set_ramp_inputvar templates/cpu-stress.yaml CPU_ENABLED "$cpu_enabled" true
set_ramp_inputvar templates/cpu-stress.yaml CPU_REPLICAS_STEP "$cpu_replicas_step"
set_ramp_inputvar templates/cpu-stress.yaml CPU_WORKERS "$cpu_workers"

mem_enabled="$(read_config MEM_ENABLED)"
mem_replicas_step="$(read_config MEM_REPLICAS_STEP)"
mem_workers="$(read_config MEM_WORKERS)"
mem_bytes="$(read_config MEM_BYTES)"

set_ramp_inputvar templates/mem-stress.yaml MEM_ENABLED "$mem_enabled" true
set_ramp_inputvar templates/mem-stress.yaml MEM_REPLICAS_STEP "$mem_replicas_step"
set_ramp_inputvar templates/mem-stress.yaml MEM_WORKERS "$mem_workers"
set_ramp_inputvar templates/mem-stress.yaml MEM_BYTES "$mem_bytes"

disk_enabled="$(read_config DISK_ENABLED)"
fio_parallelism_step="$(read_config FIO_PARALLELISM_STEP)"
fio_rw="$(read_config FIO_RW)"
fio_bs="$(read_config FIO_BS)"
fio_iodepth="$(read_config FIO_IODEPTH)"
fio_size="$(read_config FIO_SIZE)"
fio_runtime="$(read_config FIO_RUNTIME)"
fio_pvc_size="$(read_config FIO_PVC_SIZE)"
fio_pvc_name="$(read_config FIO_PVC_NAME)"
if [ -z "$fio_pvc_name" ]; then
  fio_pvc_name="noisy-neighbor-fio"
fi

fio_pvc_name_escaped="$(printf '%s' "$fio_pvc_name" | sed 's/[\\/&|]/\\\\&/g')"
fio_pvc_size_escaped="$(printf '%s' "$fio_pvc_size" | sed 's/[\\/&|]/\\\\&/g')"
sed -e "s|__NAMESPACE__|$namespace_escaped|g" -e "s|__FIO_PVC_NAME__|$fio_pvc_name_escaped|g" -e "s|__FIO_PVC_SIZE__|$fio_pvc_size_escaped|g" "$fio_pvc_template" > "$fio_pvc_rendered_file"

set_ramp_inputvar templates/disk-fio.yaml DISK_ENABLED "$disk_enabled" true
set_ramp_inputvar templates/disk-fio.yaml FIO_PARALLELISM_STEP "$fio_parallelism_step"
set_ramp_inputvar templates/disk-fio.yaml FIO_RW "$fio_rw"
set_ramp_inputvar templates/disk-fio.yaml FIO_BS "$fio_bs"
set_ramp_inputvar templates/disk-fio.yaml FIO_IODEPTH "$fio_iodepth"
set_ramp_inputvar templates/disk-fio.yaml FIO_SIZE "$fio_size"
set_ramp_inputvar templates/disk-fio.yaml FIO_RUNTIME "$fio_runtime"
set_ramp_inputvar templates/disk-fio.yaml FIO_PVC_SIZE "$fio_pvc_size"
set_ramp_inputvar templates/disk-fio.yaml FIO_PVC_NAME "$fio_pvc_name" true

set_object_inputvar fio-pvc-cleanup templates/fio-pvc-cleanup.yaml DISK_ENABLED "$disk_enabled" true
set_object_inputvar fio-pvc-cleanup templates/fio-pvc-cleanup.yaml FIO_PVC_NAME "$fio_pvc_name" true

if is_true "$dry_run"; then
  cleanup_rendered="false"
  echo "WORKLOAD=$rendered_file"
  echo "PROBE_RBAC=$probe_rbac_rendered_file"
  echo "FIO_CLEANUP_RBAC=$fio_cleanup_rbac_rendered_file"
  echo "FIO_PVC=$fio_pvc_rendered_file"
  echo "WOULD_RUN=kubectl -n $namespace_value delete deployment,job -l app.kubernetes.io/part-of=noisy-neighbor --ignore-not-found=true"
  echo "WOULD_RUN=kubectl apply -f $probe_rbac_rendered_file"
  echo "WOULD_RUN=kubectl apply -f $fio_cleanup_rbac_rendered_file"
  if [ "$disk_enabled" = "true" ]; then
    echo "WOULD_RUN=kubectl apply -f $fio_pvc_rendered_file"
  fi
  echo "WOULD_RUN=yq '.jobs[].name' $rendered_file"
  echo "WOULD_RUN=kube-burner init -c $rendered_file"
  exit 0
fi

if is_true "$print_rendered_path"; then
  echo "WORKLOAD=$rendered_file"
  echo "PROBE_RBAC=$probe_rbac_rendered_file"
  echo "FIO_CLEANUP_RBAC=$fio_cleanup_rbac_rendered_file"
  echo "FIO_PVC=$fio_pvc_rendered_file"
fi

cleanup_existing_namespaced_resources
kubectl apply -f "$probe_rbac_rendered_file"
kubectl apply -f "$fio_cleanup_rbac_rendered_file"
if [ "$disk_enabled" = "true" ]; then
  kubectl apply -f "$fio_pvc_rendered_file"
fi
echo "Rendered job names (execution order):"
yq '.jobs[].name' "$rendered_file"
kube-burner init -c "$rendered_file"
