# kube-burner noisy-neighbor harness

This repository runs a noisy-neighbor workload against Kubernetes using kube-burner, with explicit baseline -> ramp-step-1..N -> recovery phase sequencing and a final optional disk PVC cleanup phase.

## Repository structure

- `config.yaml`: all user-tunable knobs.
- `run.sh`: single entrypoint; renders and patches workload/manifests, applies prerequisites, executes phases.
- `workloads/noisy-neighbor.yaml`: base workload definition used as render input.
- `templates/probe-job.yaml`: probe Job template (generateName, duration loop).
- `templates/cpu-stress.yaml`: CPU Deployment template.
- `templates/mem-stress.yaml`: memory Deployment template.
- `templates/disk-fio.yaml`: disk Job template (fio or noop when disabled).
- `templates/fio-pvc-cleanup.yaml`: PVC cleanup Job template (or noop when disk disabled).
- `manifests/probe-rbac.yaml`: namespace + probe ServiceAccount/ClusterRole/ClusterRoleBinding.
- `manifests/fio-cleanup-rbac.yaml`: cleanup ServiceAccount/Role/RoleBinding.
- `manifests/fio-pvc.yaml`: PVC manifest template for disk fio.

## Prerequisites

- `yq` (v4 syntax required)
- `kubectl`
- `kube-burner`
- access to a Kubernetes cluster (for local testing, kind works)

## Quick start

```bash
./run.sh
```

For kind:

```bash
kind create cluster --name kb || true
kubectl config use-context kind-kb
./run.sh
```

## Runtime behavior in `run.sh`

`run.sh` performs the following on every run:

1. Reads `config.yaml`.
2. Renders prerequisite manifests (`probe-rbac`, `fio-cleanup-rbac`, and optional `fio-pvc`) by replacing template placeholders.
3. Renders `workloads/noisy-neighbor.yaml` into a temp workload file.
4. Expands ramp template job `ramp-step-1` into `ramp-step-1..STEPS`.
5. Applies config-driven `inputVars` overrides for probe/cpu/memory/disk/cleanup objects.
6. Sets per-job wait semantics (`waitWhenFinished`, `podWait`, `maxWaitTimeout`) and disables image preloading.
7. Deletes old noisy-neighbor Deployments/Jobs in the target namespace.
8. Applies prerequisite manifests (and PVC when disk is enabled).
9. Extracts each job into a standalone kube-burner config file (`runs/<ts>/build/<phase>.yaml`).
10. Executes each phase as its own `kube-burner init` invocation in strict sequential order:
    - `baseline-probes`
    - `ramp-step-1..N`
    - *(stress teardown: deletes CPU/MEM deployments and FIO jobs)*
    - `recovery-probes`
    - `fio-pvc-cleanup`

Per-phase execution guarantees sequential ordering. Stress workloads are explicitly torn down before recovery probes run, so recovery measures actual control-plane recovery under zero load.

`workloads/noisy-neighbor.yaml` is treated as a base input. At runtime, `ramp-step-1` is the template source for all ramp expansion; generated ramp jobs replace the original jobs list in the rendered file.

## Config knobs

| Key | Purpose |
| --- | --- |
| `NAMESPACE` | target namespace for workload objects and RBAC subject bindings |
| `BASELINE_DURATION` | baseline probe loop duration |
| `STEP_DURATION` | probe loop duration in each ramp step |
| `RECOVERY_DURATION` | recovery probe loop duration |
| `STEPS` | number of ramp steps (`ramp-step-1..STEPS`) |
| `PROBE_INTERVAL` | probe loop sleep interval |
| `PROBE_TIMEOUT` | per-probe kubectl request timeout |
| `CPU_ENABLED` | enable CPU stress deployment template |
| `CPU_REPLICAS_STEP` | CPU stress replicas per step (linear: total at step N = N × this value) |
| `CPU_WORKERS` | `stress --cpu` worker count per pod |
| `MEM_ENABLED` | enable memory stress deployment template |
| `MEM_REPLICAS_STEP` | memory stress replicas per step (linear: total at step N = N × this value) |
| `MEM_WORKERS` | `stress --vm` worker count per pod |
| `MEM_BYTES` | memory stress target bytes per worker |
| `DISK_ENABLED` | enable fio disk jobs and PVC lifecycle |
| `FIO_PARALLELISM_STEP` | fio Job parallelism/completions per step (linear: total at step N = N × this value) |
| `FIO_RW` | fio rw mode |
| `FIO_BS` | fio block size |
| `FIO_IODEPTH` | fio iodepth |
| `FIO_SIZE` | fio file size |
| `FIO_RUNTIME` | fio runtime per pod |
| `FIO_PVC_SIZE` | requested PVC size for fio workload |
| `FIO_PVC_NAME` | PVC name used by fio and cleanup |
| `KUBECONFIG` | optional kubeconfig override exported by `run.sh` |

## DRY_RUN and render inspection

Render-only mode:

```bash
DRY_RUN=true ./run.sh
```

Outputs include:

- `WORKLOAD=...`
- `PROBE_RBAC=...`
- `FIO_CLEANUP_RBAC=...`
- `FIO_PVC=...`
- `WOULD_RUN=...` for all kubectl calls
- one `WOULD_RUN=kube-burner init -c ...` per phase file in execution order

To print rendered paths during a real run:

```bash
PRINT_RENDERED_PATH=true ./run.sh
```

## Run artifacts

Each run creates a `runs/<timestamp>/` directory containing:

- `build/` — per-phase kube-burner config files (`baseline-probes.yaml`, `ramp-step-1.yaml`, etc.)
- `<phase>.log` — per-phase kube-burner log (e.g. `baseline-probes.log`, `ramp-step-1.log`)
- `probe.jsonl` — probe measurements from all phases (collected from pod logs)
- `summary.csv` — per-phase, per-probe aggregate metrics (count, avg, p95, errors)

## Validating phase sequencing

Run and capture logs:

```bash
./run.sh 2>&1 | tee /tmp/noisy-neighbor-run.log
```

Verify sequential execution:

```bash
grep -E '>>> Phase:|==> Tearing down|==> Stress teardown complete' /tmp/noisy-neighbor-run.log
```

Expected output shows phases in strict order, with stress teardown before recovery.

## Probe output

Each probe emits one JSON line per measurement:

```json
{"ts":"...","phase":"baseline","probe":"readyz","seq":1,"latency_ms":35,"exit_code":0,"error":""}
```

Fields: `ts` (ISO-8601), `phase`, `probe` (readyz/nodes/pods), `seq` (monotonic within phase), `latency_ms`, `exit_code`, `error` (stderr, truncated to 200 chars, only populated on failure).

To inspect probe pods manually:

```bash
NS="$(yq -r '.NAMESPACE // "noisy-neighbor"' config.yaml)"
kubectl -n "$NS" get jobs -l app.kubernetes.io/component=probe
kubectl -n "$NS" logs -l app.kubernetes.io/component=probe --tail=-1 --prefix=true
```

## Notes

- RBAC objects are intentionally externalized in `manifests/` and are not embedded in workload templates.
- The base workload file may contain defaults that are overridden at runtime by `run.sh`; runtime patching is the source of truth.
- Phase jobs have `cleanup: false` so resources remain available for post-run log collection.
- Stress workloads (CPU/MEM deployments, FIO jobs) are explicitly torn down between the last ramp step and recovery probes.
- Cleanup of leftovers is handled by `cleanup.sh` (and `CLEANUP_BEFORE_RUN` in `config.yaml`) before the next run.
- Step ramp is linear: each step adds `REPLICAS_STEP` pods; total at step N = N × `REPLICAS_STEP`.
