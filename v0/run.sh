#!/usr/bin/env bash
set -uo pipefail

V0_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$V0_DIR/config.yaml}"

KB_REQUIRED_VERSION="v2.4.0"

resolve_kb() {
  # 1) Explicit override
  if [ -n "${KB_BIN:-}" ] && [ -x "$KB_BIN" ]; then
    if [ "${KB_ALLOW_ANY:-0}" != "1" ]; then
      if ! "$KB_BIN" version 2>&1 | grep -q "${KB_REQUIRED_VERSION#v}"; then
        echo "ERROR: KB_BIN ($KB_BIN) does not report $KB_REQUIRED_VERSION:"
        "$KB_BIN" version 2>&1 | head -5
        echo "Set KB_ALLOW_ANY=1 to accept any version, or point KB_BIN to a $KB_REQUIRED_VERSION binary."
        exit 1
      fi
    fi
    echo ">>> Using KB_BIN from environment: $KB_BIN"
    KB="$KB_BIN"
    return 0
  fi

  # 2) System kube-burner matching required version
  if command -v kube-burner &>/dev/null; then
    if kube-burner version 2>&1 | grep -q "${KB_REQUIRED_VERSION#v}"; then
      KB="$(command -v kube-burner)"
      echo ">>> Using system kube-burner ($KB_REQUIRED_VERSION): $KB"
      return 0
    fi
  fi

  # 3) Local binary, install if missing
  KB="$V0_DIR/bin/kube-burner"
  if [ ! -x "$KB" ]; then
    echo ">>> kube-burner not found — installing $KB_REQUIRED_VERSION"
    bash "$V0_DIR/scripts/install-kube-burner.sh"
  fi

  if [ ! -x "$KB" ]; then
    echo "ERROR: kube-burner binary not available at $KB"
    echo "Set KB_BIN to a local kube-burner path and re-run."
    exit 1
  fi
  echo ">>> Using local kube-burner: $KB"
}

resolve_kb
cd "$V0_DIR"

# ---------------------------------------------------------------------------
# Parse flat config.yaml into uppercased env vars (only if not already set)
# ---------------------------------------------------------------------------
parse_config() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS='' read -r line; do
    line="${line%%#*}"                       # strip comments
    [[ -z "$line" || ! "$line" =~ : ]] && continue
    key="${line%%:*}"; key="${key// /}"
    val="${line#*:}";  val="${val# }"; val="${val% }"
    key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    # only set if not already exported
    if [ -z "${!key+x}" ]; then
      export "$key=$val"
    fi
  done < "$file"
}

parse_config "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# Defaults (overridable by config.yaml or environment)
# ---------------------------------------------------------------------------
BASELINE_PROBE_DURATION="${BASELINE_PROBE_DURATION:-10}"
BASELINE_PROBE_INTERVAL="${BASELINE_PROBE_INTERVAL:-2}"
RAMP_STEPS="${RAMP_STEPS:-2}"
RAMP_CPU_REPLICAS="${RAMP_CPU_REPLICAS:-1}"
RAMP_CPU_MILLICORES="${RAMP_CPU_MILLICORES:-50}"
RAMP_MEM_REPLICAS="${RAMP_MEM_REPLICAS:-1}"
RAMP_MEM_MB="${RAMP_MEM_MB:-32}"
RECOVERY_PROBE_DURATION="${RECOVERY_PROBE_DURATION:-10}"
RECOVERY_PROBE_INTERVAL="${RECOVERY_PROBE_INTERVAL:-2}"
RAMP_PROBE_DURATION="${RAMP_PROBE_DURATION:-10}"
RAMP_PROBE_INTERVAL="${RAMP_PROBE_INTERVAL:-2}"
KB_TIMEOUT="${KB_TIMEOUT:-5m}"
SKIP_LOG_FILE="${SKIP_LOG_FILE:-true}"

# ---------------------------------------------------------------------------
# Run directory — all artifacts land here
# ---------------------------------------------------------------------------
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-$V0_DIR/runs/$RUN_ID}"
mkdir -p "$RUN_DIR"
echo ">>> Run artifacts: $RUN_DIR"

MAIN_RC=0

# ---------------------------------------------------------------------------
# Artifact salvage — ALWAYS runs, even on failure
# ---------------------------------------------------------------------------
collect_artifacts() {
  echo ">>> Collecting artifacts into $RUN_DIR"
  # kube-burner log files
  for f in "$V0_DIR"/kube-burner-*.log; do
    [ -f "$f" ] && mv "$f" "$RUN_DIR/" 2>/dev/null || true
  done
  # collected-metrics dirs
  if [ -d "$V0_DIR/collected-metrics" ]; then
    mv "$V0_DIR/collected-metrics" "$RUN_DIR/" 2>/dev/null || true
  fi
  # generate summary
  bash "$V0_DIR/scripts/summarize.sh" "$RUN_DIR" 2>/dev/null || true
  echo ">>> Artifacts collected. main_rc=$MAIN_RC"
}
trap collect_artifacts EXIT

# ---------------------------------------------------------------------------
# Log kube-burner binary path and version
# ---------------------------------------------------------------------------
{
  echo "binary: $KB"
  "$KB" version 2>&1
} > "$RUN_DIR/kb-version.txt"
echo ">>> kube-burner version:"
cat "$RUN_DIR/kb-version.txt"

# ---------------------------------------------------------------------------
# Helper: record a phase result into phases.jsonl
# ---------------------------------------------------------------------------
record_phase() {
  local phase="$1" uuid="$2" rc="$3" start="$4" end_t="$5"
  local elapsed=$((end_t - start))
  printf '{"phase":"%s","uuid":"%s","rc":%d,"start":%d,"end":%d,"elapsed_s":%d}\n' \
    "$phase" "$uuid" "$rc" "$start" "$end_t" "$elapsed" \
    >> "$RUN_DIR/phases.jsonl"
}

# ---------------------------------------------------------------------------
# Helper: collect probe pod logs → probe.jsonl
# ---------------------------------------------------------------------------
collect_probe_logs() {
  local phase="$1"
  local job_name="probe-${phase}"
  echo ">>> Collecting probe logs for phase=$phase job=$job_name"
  kubectl logs -n kb-probe "job/${job_name}" --tail=-1 \
    >> "$RUN_DIR/probe.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: run a probe phase via kube-burner
# ---------------------------------------------------------------------------
run_probe() {
  local phase="$1" duration="$2" interval="$3"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  local start_ts rc
  start_ts=$(date +%s)

  echo ""
  echo "========================================"
  echo "  PROBE: $phase  (${duration}s every ${interval}s)"
  echo "========================================"

  local kb_flags=()
  kb_flags+=(-c "$V0_DIR/workloads/probe.yaml")
  kb_flags+=(--uuid "$uuid")
  kb_flags+=(--timeout "$KB_TIMEOUT")
  if [ "$SKIP_LOG_FILE" = "true" ]; then
    kb_flags+=(--skip-log-file)
  fi

  export PHASE="$phase"
  export PROBE_DURATION="$duration"
  export PROBE_INTERVAL="$interval"

  rc=0
  "$KB" init "${kb_flags[@]}" 2>&1 | tee "$RUN_DIR/phase-${phase}.log" || rc=$?

  local end_ts
  end_ts=$(date +%s)
  record_phase "$phase" "$uuid" "$rc" "$start_ts" "$end_ts"
  collect_probe_logs "$phase"
  return $rc
}

# ---------------------------------------------------------------------------
# Helper: run a ramp step via kube-burner
# ---------------------------------------------------------------------------
run_ramp_step() {
  local step="$1"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  local start_ts rc
  start_ts=$(date +%s)

  echo ""
  echo "========================================"
  echo "  RAMP STEP $step"
  echo "========================================"

  local kb_flags=()
  kb_flags+=(-c "$V0_DIR/workloads/ramp-step.yaml")
  kb_flags+=(--uuid "$uuid")
  kb_flags+=(--timeout "$KB_TIMEOUT")
  if [ "$SKIP_LOG_FILE" = "true" ]; then
    kb_flags+=(--skip-log-file)
  fi

  export STEP="$step"
  export CPU_MILLICORES="$RAMP_CPU_MILLICORES"
  export CPU_REPLICAS="$RAMP_CPU_REPLICAS"
  export MEM_MB="$RAMP_MEM_MB"
  export MEM_REPLICAS="$RAMP_MEM_REPLICAS"
  export RAMP_PROBE_DURATION
  export RAMP_PROBE_INTERVAL

  rc=0
  "$KB" init "${kb_flags[@]}" 2>&1 | tee "$RUN_DIR/phase-ramp-step-${step}.log" || rc=$?

  local end_ts
  end_ts=$(date +%s)
  record_phase "ramp-step-${step}" "$uuid" "$rc" "$start_ts" "$end_ts"
  collect_probe_logs "ramp-step-${step}"
  return $rc
}

# ---------------------------------------------------------------------------
# Helper: teardown stress namespaces
# ---------------------------------------------------------------------------
teardown_stress() {
  echo ""
  echo "========================================"
  echo "  TEARDOWN"
  echo "========================================"
  local start_ts rc=0
  start_ts=$(date +%s)

  for i in $(seq 1 "$RAMP_STEPS"); do
    echo ">>> Deleting namespace kb-stress-$i"
    kubectl delete ns "kb-stress-$i" --ignore-not-found --wait=true --timeout=120s 2>&1 || true
  done

  local end_ts
  end_ts=$(date +%s)
  record_phase "teardown" "n/a" "$rc" "$start_ts" "$end_ts"
}

# ===========================================================================
#  MAIN SEQUENCE
# ===========================================================================
echo ">>> Setting up RBAC for probes"
kubectl apply -f "$V0_DIR/manifests/probe-rbac.yaml"

# --- BASELINE ---
run_probe "baseline" "$BASELINE_PROBE_DURATION" "$BASELINE_PROBE_INTERVAL" || MAIN_RC=1

# --- RAMP STEPS ---
for step in $(seq 1 "$RAMP_STEPS"); do
  run_ramp_step "$step" || MAIN_RC=1
done

# --- TEARDOWN (always, even if ramp failed) ---
teardown_stress || true

# --- RECOVERY ---
run_probe "recovery" "$RECOVERY_PROBE_DURATION" "$RECOVERY_PROBE_INTERVAL" || MAIN_RC=1

echo ""
echo "========================================"
if [ "$MAIN_RC" -eq 0 ]; then
  echo "  ALL PHASES PASSED"
else
  echo "  ONE OR MORE PHASES FAILED (rc=$MAIN_RC)"
fi
echo "  Artifacts: $RUN_DIR"
echo "========================================"

exit "$MAIN_RC"
