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
  echo "yq is required (v4 syntax). Please install yq and retry." >&2
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

require_config() {
  key="$1"
  value="$(read_config "$key")"
  if [ -z "$value" ]; then
    echo "$key must be set in config.yaml" >&2
    exit 1
  fi
  printf '%s' "$value"
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

ensure_namespace() {
  if ! kubectl get namespace "$namespace_value" >/dev/null 2>&1; then
    kubectl create namespace "$namespace_value"
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
          (.objects[]? | select(.objectTemplate == "templates/cpu-stress.yaml" and has("inputVars")) | .inputVars.STEP) = (env(STEP) | tonumber) |
          (.objects[]? | select(.objectTemplate == "templates/mem-stress.yaml" and has("inputVars")) | .inputVars.STEP) = (env(STEP) | tonumber) |
          (.objects[]? | select(.objectTemplate == "templates/disk-fio.yaml" and has("inputVars")) | .inputVars.STEP) = (env(STEP) | tonumber) |
          (.objects[]? | select(.objectTemplate == "templates/probe-job.yaml" and has("inputVars")) | .inputVars.PROBE_PHASE) = "ramp-step-" + strenv(STEP)
        )
      ]
    ' "$rendered_file"
    step=$((step + 1))
  done

  RECOVERY_JOB="$recovery_job" yq -i '.jobs += [(strenv(RECOVERY_JOB) | from_yaml)]' "$rendered_file"
  CLEANUP_JOB="$cleanup_job" yq -i '.jobs += [(strenv(CLEANUP_JOB) | from_yaml)]' "$rendered_file"
}

collect_probe_logs() {
  output_file="$1"
  if ! kubectl -n "$namespace_value" logs -l app.kubernetes.io/name=noisy-neighbor,app.kubernetes.io/component=probe --tail=-1 --prefix=false > "$output_file"; then
    : > "$output_file"
    echo "warning: failed to collect probe logs (wrote empty $output_file)" >&2
  fi
}

generate_summary_csv() {
  probe_jsonl_file="$1"
  summary_csv_file="$2"
  parsed_tsv="$(mktemp /tmp/noisy-neighbor.probe.tsv.XXXXXX)"
  sorted_tsv="$(mktemp /tmp/noisy-neighbor.probe.sorted.tsv.XXXXXX)"

  awk '
    function extract_string(key,    pattern, start, rest, stop) {
      pattern = "\"" key "\":\""
      start = index($0, pattern)
      if (start == 0) {
        return ""
      }
      rest = substr($0, start + length(pattern))
      stop = index(rest, "\"")
      if (stop == 0) {
        return ""
      }
      return substr(rest, 1, stop - 1)
    }

    function extract_number(key,    pattern, start, rest) {
      pattern = "\"" key "\":"
      start = index($0, pattern)
      if (start == 0) {
        return ""
      }
      rest = substr($0, start + length(pattern))
      sub(/^[[:space:]]*/, "", rest)
      if (match(rest, /^-?[0-9]+/)) {
        return substr(rest, RSTART, RLENGTH)
      }
      return ""
    }

    $0 ~ /^\{/ {
      phase = extract_string("phase")
      probe = extract_string("probe")
      latency = extract_number("latency_ms")
      exit_code = extract_number("exit_code")
      if (phase != "" && probe != "" && latency != "" && exit_code != "") {
        print phase "\t" probe "\t" latency "\t" exit_code
      }
    }
  ' "$probe_jsonl_file" > "$parsed_tsv"

  echo "phase,probe,count,avg_latency_ms,p95_latency_ms,errors" > "$summary_csv_file"

  if [ ! -s "$parsed_tsv" ]; then
    rm -f "$parsed_tsv" "$sorted_tsv"
    return 0
  fi

  sort -t "$(printf '\t')" -k1,1 -k2,2 -k3,3n "$parsed_tsv" > "$sorted_tsv"

  awk -F '\t' -v OFS=',' -v OUT="$summary_csv_file" '
    function flush_group(    idx, avg, p95) {
      if (group_count == 0) {
        return
      }
      idx = int((group_count * 95 + 99) / 100)
      if (idx < 1) {
        idx = 1
      }
      if (idx > group_count) {
        idx = group_count
      }
      p95 = latencies[idx]
      avg = group_sum / group_count
      printf "%s,%s,%d,%.2f,%d,%d\n", group_phase, group_probe, group_count, avg, p95, group_errors >> OUT
    }

    {
      phase = $1
      probe = $2
      latency_ms = $3 + 0
      exit_code = $4 + 0

      if (group_count == 0) {
        group_phase = phase
        group_probe = probe
      }

      if (phase != group_phase || probe != group_probe) {
        flush_group()
        delete latencies
        group_count = 0
        group_sum = 0
        group_errors = 0
        group_phase = phase
        group_probe = probe
      }

      group_count++
      group_sum += latency_ms
      if (exit_code != 0) {
        group_errors++
      }
      latencies[group_count] = latency_ms
    }

    END {
      flush_group()
    }
  ' "$sorted_tsv"

  rm -f "$parsed_tsv" "$sorted_tsv"
}

extract_phase_files() {
  mkdir -p "$build_dir"
  phase_order_file="$build_dir/.phase-order"
  job_count="$(yq '.jobs | length' "$rendered_file")"
  : > "$phase_order_file"
  job_idx=0
  while [ "$job_idx" -lt "$job_count" ]; do
    job_name="$(yq -r ".jobs[$job_idx].name" "$rendered_file")"
    phase_file="$build_dir/${job_name}.yaml"
    yq "{ \"global\": .global, \"jobs\": [.jobs[$job_idx]] }" "$rendered_file" > "$phase_file"
    echo "$job_name" >> "$phase_order_file"
    job_idx=$((job_idx + 1))
  done
}

teardown_stress() {
  echo ""
  echo "==> Tearing down stress workloads before recovery"
  kubectl -n "$namespace_value" delete deployment \
    -l "app.kubernetes.io/part-of=noisy-neighbor,app.kubernetes.io/component=cpu-stress" \
    --ignore-not-found=true
  kubectl -n "$namespace_value" delete deployment \
    -l "app.kubernetes.io/part-of=noisy-neighbor,app.kubernetes.io/component=mem-stress" \
    --ignore-not-found=true
  kubectl -n "$namespace_value" delete job \
    -l "app.kubernetes.io/part-of=noisy-neighbor,app.kubernetes.io/component=disk-fio" \
    --ignore-not-found=true
  echo "==> Waiting for stress pods to terminate (timeout 2m)"
  kubectl -n "$namespace_value" wait pod \
    -l "app.kubernetes.io/component in (cpu-stress,mem-stress,disk-fio)" \
    --for=delete --timeout=2m 2>/dev/null || echo "warning: timed out waiting for stress pod deletion"
  echo "==> Stress teardown complete"
  echo ""
}

run_phase() {
  phase_name="$1"
  phase_file="$2"
  phase_log="$run_output_dir/${phase_name}.log"
  echo ">>> Phase: $phase_name"
  if kube-burner init -c "$phase_file" > "$phase_log" 2>&1; then
    cat "$phase_log"
    return 0
  fi
  if grep -qi "preLoadImages\|preloadimages\|unknown field" "$phase_log" 2>/dev/null; then
    echo "warning: preLoadImages not supported by this kube-burner build; retrying $phase_name without it"
    yq -i 'del(.global.preLoadImages)' "$phase_file"
    if kube-burner init -c "$phase_file" > "$phase_log" 2>&1; then
      cat "$phase_log"
      return 0
    fi
  fi
  cat "$phase_log" >&2
  echo "FATAL: phase $phase_name failed; see $phase_log" >&2
  return 1
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

probe_interval="$(require_config PROBE_INTERVAL)"
probe_timeout="$(require_config PROBE_TIMEOUT)"
baseline_duration="$(require_config BASELINE_DURATION)"
step_duration="$(require_config STEP_DURATION)"
recovery_duration="$(require_config RECOVERY_DURATION)"

cpu_enabled="$(require_config CPU_ENABLED)"
cpu_replicas_step="$(require_config CPU_REPLICAS_STEP)"
cpu_workers="$(require_config CPU_WORKERS)"

mem_enabled="$(require_config MEM_ENABLED)"
mem_replicas_step="$(require_config MEM_REPLICAS_STEP)"
mem_workers="$(require_config MEM_WORKERS)"
mem_bytes="$(require_config MEM_BYTES)"

disk_enabled="$(require_config DISK_ENABLED)"
fio_parallelism_step="$(require_config FIO_PARALLELISM_STEP)"
fio_rw="$(require_config FIO_RW)"
fio_bs="$(require_config FIO_BS)"
fio_iodepth="$(require_config FIO_IODEPTH)"
fio_size="$(require_config FIO_SIZE)"
fio_runtime="$(require_config FIO_RUNTIME)"
fio_pvc_size="$(require_config FIO_PVC_SIZE)"
fio_pvc_name="$(read_config FIO_PVC_NAME)"
if [ -z "$fio_pvc_name" ]; then
  fio_pvc_name="noisy-neighbor-fio"
fi

run_timestamp="$(date +%Y%m%d-%H%M%S)"
run_output_dir="$script_dir/runs/$run_timestamp"
run_suffix=1
while [ -e "$run_output_dir" ]; do
  run_output_dir="$script_dir/runs/${run_timestamp}-$run_suffix"
  run_suffix=$((run_suffix + 1))
done
probe_output_file="$run_output_dir/probe.jsonl"
summary_output_file="$run_output_dir/summary.csv"

namespace_escaped="$(printf '%s' "$namespace_value" | sed 's/[\\/&|]/\\\\&/g')"
sed "s|__NAMESPACE__|$namespace_escaped|g" "$probe_rbac_template" > "$probe_rbac_rendered_file"
sed "s|__NAMESPACE__|$namespace_escaped|g" "$fio_cleanup_rbac_template" > "$fio_cleanup_rbac_rendered_file"

fio_pvc_name_escaped="$(printf '%s' "$fio_pvc_name" | sed 's/[\\/&|]/\\\\&/g')"
fio_pvc_size_escaped="$(printf '%s' "$fio_pvc_size" | sed 's/[\\/&|]/\\\\&/g')"
sed -e "s|__NAMESPACE__|$namespace_escaped|g" -e "s|__FIO_PVC_NAME__|$fio_pvc_name_escaped|g" -e "s|__FIO_PVC_SIZE__|$fio_pvc_size_escaped|g" "$fio_pvc_template" > "$fio_pvc_rendered_file"

set_yaml_value '.jobs[].namespace' "$namespace_value" true
set_yaml_value '.jobs[].objects[].inputVars.NAMESPACE' "$namespace_value" true

expand_ramp_steps "$steps_value"

set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_DURATION "$baseline_duration" true
set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_INTERVAL "$probe_interval" true
set_object_inputvar baseline-probes templates/probe-job.yaml PROBE_TIMEOUT "$probe_timeout" true

set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_DURATION)' "$step_duration" true
set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_INTERVAL)' "$probe_interval" true
set_yaml_value '(.jobs[] | select(.name | test("^ramp-step-[0-9]+$")) | .objects[] | select(.objectTemplate=="templates/probe-job.yaml") | .inputVars.PROBE_TIMEOUT)' "$probe_timeout" true

set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_DURATION "$recovery_duration" true
set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_INTERVAL "$probe_interval" true
set_object_inputvar recovery-probes templates/probe-job.yaml PROBE_TIMEOUT "$probe_timeout" true

set_ramp_inputvar templates/cpu-stress.yaml CPU_ENABLED "$cpu_enabled" true
set_ramp_inputvar templates/cpu-stress.yaml CPU_REPLICAS_STEP "$cpu_replicas_step"
set_ramp_inputvar templates/cpu-stress.yaml CPU_WORKERS "$cpu_workers"

set_ramp_inputvar templates/mem-stress.yaml MEM_ENABLED "$mem_enabled" true
set_ramp_inputvar templates/mem-stress.yaml MEM_REPLICAS_STEP "$mem_replicas_step"
set_ramp_inputvar templates/mem-stress.yaml MEM_WORKERS "$mem_workers"
set_ramp_inputvar templates/mem-stress.yaml MEM_BYTES "$mem_bytes" true

set_ramp_inputvar templates/disk-fio.yaml DISK_ENABLED "$disk_enabled" true
set_ramp_inputvar templates/disk-fio.yaml FIO_PARALLELISM_STEP "$fio_parallelism_step"
set_ramp_inputvar templates/disk-fio.yaml FIO_RW "$fio_rw" true
set_ramp_inputvar templates/disk-fio.yaml FIO_BS "$fio_bs" true
set_ramp_inputvar templates/disk-fio.yaml FIO_IODEPTH "$fio_iodepth"
set_ramp_inputvar templates/disk-fio.yaml FIO_SIZE "$fio_size" true
set_ramp_inputvar templates/disk-fio.yaml FIO_RUNTIME "$fio_runtime" true
set_ramp_inputvar templates/disk-fio.yaml FIO_PVC_SIZE "$fio_pvc_size" true
set_ramp_inputvar templates/disk-fio.yaml FIO_PVC_NAME "$fio_pvc_name" true

set_object_inputvar fio-pvc-cleanup templates/fio-pvc-cleanup.yaml DISK_ENABLED "$disk_enabled" true
set_object_inputvar fio-pvc-cleanup templates/fio-pvc-cleanup.yaml FIO_PVC_NAME "$fio_pvc_name" true

# Wait for each job to finish before starting the next (phase order: baseline -> ramp -> recovery -> cleanup).
yq -i '.global.waitWhenFinished = true' "$rendered_file"

yq -i '
  .jobs[] |= (
    .waitWhenFinished = true |
    .podWait = true |
    .verifyObjects = false |
    .jobPause = "0s" |
    .maxWaitTimeout = "10m"
  )
' "$rendered_file"

yq -i '.global.preLoadImages = false' "$rendered_file"

build_dir="$run_output_dir/build"

cleanup_before_run="$(read_config CLEANUP_BEFORE_RUN)"
if [ -z "$cleanup_before_run" ]; then
  cleanup_before_run="true"
fi

if is_true "$dry_run"; then
  cleanup_rendered="false"
  mkdir -p "$run_output_dir"
  extract_phase_files
  echo "WORKLOAD=$rendered_file"
  echo "PROBE_RBAC=$probe_rbac_rendered_file"
  echo "FIO_CLEANUP_RBAC=$fio_cleanup_rbac_rendered_file"
  echo "FIO_PVC=$fio_pvc_rendered_file"
  echo "RUN_OUTPUT_DIR=$run_output_dir"
  echo "BUILD_DIR=$build_dir"
  if is_true "$cleanup_before_run"; then
    echo "WOULD_RUN=$script_dir/cleanup.sh $namespace_value $fio_pvc_name"
  fi
  echo "WOULD_RUN=kubectl get namespace $namespace_value >/dev/null 2>&1 || kubectl create namespace $namespace_value"
  echo "WOULD_RUN=kubectl apply -f $probe_rbac_rendered_file"
  if is_true "$disk_enabled"; then
    echo "WOULD_RUN=kubectl apply -f $fio_pvc_rendered_file"
    echo "WOULD_RUN=kubectl apply -f $fio_cleanup_rbac_rendered_file"
  fi
  echo ""
  echo "Rendered job names (execution order):"
  yq '.jobs[].name' "$rendered_file"
  echo ""
  echo "Per-phase execution plan:"
  while IFS= read -r _phase_name || [ -n "$_phase_name" ]; do
    _phase_file="$build_dir/${_phase_name}.yaml"
    if [ "$_phase_name" = "recovery-probes" ]; then
      echo "WOULD_RUN=teardown_stress (delete cpu-stress/mem-stress deploys + disk-fio jobs)"
    fi
    echo "WOULD_RUN=kube-burner init -c $_phase_file"
  done < "$build_dir/.phase-order"
  echo ""
  echo "WOULD_RUN=kubectl -n $namespace_value logs -l app.kubernetes.io/name=noisy-neighbor,app.kubernetes.io/component=probe --tail=-1 --prefix=false > $probe_output_file"
  echo "WOULD_WRITE=$summary_output_file"
  exit 0
fi

if is_true "$print_rendered_path"; then
  echo "WORKLOAD=$rendered_file"
  echo "PROBE_RBAC=$probe_rbac_rendered_file"
  echo "FIO_CLEANUP_RBAC=$fio_cleanup_rbac_rendered_file"
  echo "FIO_PVC=$fio_pvc_rendered_file"
  echo "BUILD_DIR=$build_dir"
fi

mkdir -p "$run_output_dir"
extract_phase_files

if is_true "$cleanup_before_run"; then
  "$script_dir/cleanup.sh" "$namespace_value" "$fio_pvc_name"
fi

ensure_namespace
kubectl apply -f "$probe_rbac_rendered_file"
if is_true "$disk_enabled"; then
  kubectl apply -f "$fio_pvc_rendered_file"
  kubectl apply -f "$fio_cleanup_rbac_rendered_file"
fi

echo "Rendered job names (execution order):"
yq '.jobs[].name' "$rendered_file"
echo "Run output directory: $run_output_dir"
echo ""

run_failed=""
while IFS= read -r phase_name || [ -n "$phase_name" ]; do
  phase_file="$build_dir/${phase_name}.yaml"
  if [ "$phase_name" = "recovery-probes" ]; then
    teardown_stress
  fi
  if ! run_phase "$phase_name" "$phase_file"; then
    echo "FATAL: phase $phase_name failed; aborting remaining phases" >&2
    run_failed="$phase_name"
    break
  fi
  echo ""
done < "$build_dir/.phase-order"

collect_probe_logs "$probe_output_file"
generate_summary_csv "$probe_output_file" "$summary_output_file"

echo "probe.jsonl: $probe_output_file"
echo "summary.csv: $summary_output_file"

if [ -n "$run_failed" ]; then
  exit 1
fi
