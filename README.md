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
6. Enforces phase wait semantics for `baseline-probes`, `ramp-step-*`, and `recovery-probes`:
   - `waitWhenFinished: true`
   - `podWait: false`
   - `verifyObjects: false`
   - `jobPause: 0s`
   - `maxWaitTimeout: 10m`
7. Deletes old noisy-neighbor Deployments/Jobs in the target namespace.
8. Applies prerequisite manifests (and PVC when disk is enabled).
9. Executes each job as its own kube-burner invocation in strict order:
   - `baseline-probes`
   - `ramp-step-1..N`
   - `recovery-probes`
   - `fio-pvc-cleanup`

This per-job execution guarantees phase serialization even with generateName Jobs and avoids overlap between baseline/ramp/recovery.

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
| `CPU_REPLICAS_STEP` | CPU replicas multiplier per step |
| `CPU_WORKERS` | `stress --cpu` worker count per pod |
| `MEM_ENABLED` | enable memory stress deployment template |
| `MEM_REPLICAS_STEP` | memory replicas multiplier per step |
| `MEM_WORKERS` | `stress --vm` worker count per pod |
| `MEM_BYTES` | memory stress target bytes per worker |
| `DISK_ENABLED` | enable fio disk jobs and PVC lifecycle |
| `FIO_PARALLELISM_STEP` | fio Job parallelism/completions multiplier per step |
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

- kube-burner writes one `kube-burner-<uuid>.log` file per phase invocation.
- If you run with `tee`, you also get a single combined console log that shows cross-phase ordering.

## Validating phase wait behavior

Run and capture logs:

```bash
./run.sh 2>&1 | tee /tmp/noisy-neighbor-run.log
```

Check ordering and wait/completion markers:

```bash
grep -E 'Initializing measurements for job: (baseline-probes|ramp-step-[0-9]+|recovery-probes)|Waiting up to 10m0s for actions to be completed|Actions in namespace .* completed' /tmp/noisy-neighbor-run.log
```

Expected pattern is repeating per phase in order:

1. `Initializing measurements for job: <phase>`
2. `Waiting up to 10m0s for actions to be completed`
3. `Actions in namespace <ns> completed`

Then the next phase starts.

## Probe output

```bash
NS="$(yq -r '.NAMESPACE // "noisy-neighbor"' config.yaml)"
kubectl -n "$NS" get jobs -l app.kubernetes.io/component=probe
kubectl -n "$NS" logs -l app.kubernetes.io/component=probe --tail=-1 --prefix=true
```

## Notes

- RBAC objects are intentionally externalized in `manifests/` and are not embedded in workload templates.
- The base workload file may contain defaults that are overridden at runtime by `run.sh`; runtime patching is the source of truth.
