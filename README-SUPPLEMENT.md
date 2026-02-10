# Supplemental Guide: File Breakdown, Workflow & Usage

A short reference for what each file does, how a run flows, and how to configure and execute it.

---

## What Each File Does

| File | Role |
|------|------|
| **config.yaml** | Single source of configuration: namespace, phase durations, step count, probe settings, CPU/memory/disk toggles and tuning. All values are read by `run.sh`. |
| **run.sh** | Main entrypoint. Reads config, renders manifests and workload with `yq`/`sed`, optionally runs `cleanup.sh`, applies RBAC/PVC, runs kube-burner, then collects probe logs and writes `probe.jsonl` + `summary.csv` under `runs/<timestamp>/`. |
| **cleanup.sh** | Idempotent teardown: removes cluster- and namespace-scoped RBAC, workloads (deployments/jobs/pods), and the FIO PVC. Optional args: `[NAMESPACE] [FIO_PVC_NAME]`. |
| **workloads/noisy-neighbor.yaml** | Base kube-burner workload: defines job sequence (baseline-probes, ramp-step-1 template, recovery-probes, fio-pvc-cleanup) and references templates. `run.sh` copies it to a temp file and injects config-driven `inputVars` and expands ramp steps. |
| **templates/probe-job.yaml** | Probe Job template: runs a loop that periodically hits cluster health (e.g. `/readyz`) and logs latency; used in baseline, each ramp step, and recovery. |
| **templates/cpu-stress.yaml** | CPU stress Deployment template; can be disabled or scaled per step via `CPU_ENABLED`, `CPU_REPLICAS_STEP`, `CPU_WORKERS`. |
| **templates/mem-stress.yaml** | Memory stress Deployment template; toggled and tuned via `MEM_*` config keys. |
| **templates/disk-fio.yaml** | FIO disk Job template; when `DISK_ENABLED` is true, runs fio against the shared PVC. |
| **templates/fio-pvc-cleanup.yaml** | Final-phase Job that cleans up FIO PVC (or no-op when disk is disabled). |
| **manifests/probe-rbac.yaml** | Namespace + ServiceAccount + ClusterRole + ClusterRoleBinding for the probe (e.g. `/readyz`). Placeholders: `__NAMESPACE__`. |
| **manifests/fio-cleanup-rbac.yaml** | ServiceAccount + Role + RoleBinding for the FIO cleanup Job. Placeholders: `__NAMESPACE__`. |
| **manifests/fio-pvc.yaml** | PVC used by FIO jobs. Placeholders: `__NAMESPACE__`, `__FIO_PVC_NAME__`, `__FIO_PVC_SIZE__`. |
| **runs/<timestamp>/** | Per-run output: `kube-burner.log`, `probe.jsonl` (raw probe log lines), `summary.csv` (per-phase/probe stats: count, avg/p95 latency, errors). |

---

## General Workflow

1. **Config** – You edit `config.yaml` (namespace, durations, STEPS, CPU/MEM/DISK toggles, FIO/cleanup options).
2. **Run** – You execute `./run.sh`. Optionally, `CLEANUP_BEFORE_RUN: "true"` runs `./cleanup.sh` first to remove prior noisy-neighbor resources.
3. **Prerequisites** – `run.sh` ensures the namespace exists and applies RBAC (and, if disk is enabled, the FIO PVC and cleanup RBAC).
4. **Phases (in order)** – kube-burner runs one job after another, each waiting to finish before the next:
   - **baseline-probes** – Probe only, no stress (baseline latency).
   - **ramp-step-1 … ramp-step-N** – For each step: create stress (CPU/memory/disk per config) and run probes alongside.
   - **recovery-probes** – Stressors are still present; probes measure “recovery” phase.
   - **fio-pvc-cleanup** – Remove FIO PVC (or no-op if disk disabled).
5. **Artifacts** – `run.sh` collects probe logs into `runs/<timestamp>/probe.jsonl` and generates `runs/<timestamp>/summary.csv`.

So: **configure → (optional cleanup) → run → inspect `runs/<timestamp>/`**.

---

## How to Use It

### Prerequisites

- **yq** (v4 syntax)
- **kubectl**
- **kube-burner**
- Access to a Kubernetes cluster (e.g. `kind` for local runs)

### Config

Edit **config.yaml**. Important knobs:

- **NAMESPACE** – Where workload and RBAC live (default: `noisy-neighbor`).
- **CLEANUP_BEFORE_RUN** – `"true"` to run `cleanup.sh` before each run (recommended).
- **BASELINE_DURATION**, **STEP_DURATION**, **RECOVERY_DURATION** – How long each probe phase runs.
- **STEPS** – Number of ramp steps (e.g. `2` → ramp-step-1, ramp-step-2).
- **PROBE_INTERVAL**, **PROBE_TIMEOUT** – Probe loop timing.
- **CPU_ENABLED**, **CPU_REPLICAS_STEP**, **CPU_WORKERS** – CPU stress.
- **MEM_ENABLED**, **MEM_REPLICAS_STEP**, **MEM_WORKERS**, **MEM_BYTES** – Memory stress.
- **DISK_ENABLED** – Enable FIO + PVC + cleanup phase.
- **FIO_*** – FIO and PVC options (only matter when DISK_ENABLED is true).
- **KUBECONFIG** – Optional; if set, `run.sh` exports it for the run.

### Run

```bash
# Default: use config.yaml, cleanup if CLEANUP_BEFORE_RUN is true, then run
./run.sh
```

**Optional:**

```bash
# See what would be run (rendered paths + WOULD_RUN commands)
DRY_RUN=true ./run.sh

# Print paths to rendered files during a real run
PRINT_RENDERED_PATH=true ./run.sh

# Use a specific kubeconfig (or set KUBECONFIG in config.yaml)
KUBECONFIG=~/path/to/kubeconfig ./run.sh
```

### Cleanup (standalone)

To remove noisy-neighbor resources without running a test:

```bash
./cleanup.sh [NAMESPACE] [FIO_PVC_NAME]
# Defaults: NAMESPACE=noisy-neighbor, FIO_PVC_NAME=noisy-neighbor-fio
```

### Output

- **runs/<timestamp>/kube-burner.log** – kube-burner output for the run.
- **runs/<timestamp>/probe.jsonl** – One JSON object per probe (phase, probe name, latency_ms, exit_code).
- **runs/<timestamp>/summary.csv** – Aggregated per phase and probe: count, avg_latency_ms, p95_latency_ms, errors.

Use `summary.csv` to compare baseline vs ramp vs recovery latency and error counts.
