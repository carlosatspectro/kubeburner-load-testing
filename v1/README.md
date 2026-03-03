# v0 -- Kubernetes Control-Plane Load-Testing Harness

A self-contained harness that uses [kube-burner](https://github.com/kube-burner/kube-burner) to measure Kubernetes API-server responsiveness under incremental CPU and memory stress. No Go toolchain required -- the harness automatically downloads a pinned kube-burner release binary.

The harness works against **any** Kubernetes cluster your `kubectl` can reach -- EKS, GKE, AKS, on-prem, or a local Kind cluster for dry runs.

## How it works

The harness runs four phases in order:

```
BASELINE probe  ->  RAMP stress (N steps)  ->  TEARDOWN  ->  RECOVERY probe
```

- **Baseline probe** -- Deploys a Job that repeatedly queries the API server (`/readyz`, list nodes, list configmaps) and records latency. This establishes the "quiet" baseline.
- **Ramp steps** -- For each step, deploys CPU-burn and memory-hog Deployments into isolated namespaces (`kb-stress-1`, `kb-stress-2`, ...) to put pressure on the cluster.
- **Teardown** -- Deletes all stress namespaces.
- **Recovery probe** -- Identical to baseline, measures how quickly the API server returns to normal latency.

Every phase is recorded to `phases.jsonl`, probe measurements go to `probe.jsonl`, and a CSV summary is generated. All artifacts land in a timestamped run directory under `v0/runs/`.

## Preflight (both modes)

Before running the harness in either mode, confirm your environment:

```bash
# 1. Verify kubectl points at the intended cluster
kubectl config current-context
kubectl get nodes -o wide

# 2. Verify kube-burner is available (auto-downloaded on first run if missing)
v0/bin/kube-burner version 2>/dev/null || echo "Will be installed automatically"
```

Prerequisites:

- **kubectl** -- configured to reach your target cluster
- **curl** -- for auto-downloading kube-burner (first run only)
- **kind** -- only needed for local dry runs (see below)
- No Go toolchain required

## Run against a real cluster

Use this workflow for EKS, GKE, AKS, on-prem, or any non-local cluster. Kind is **not** required.

### Step 1: Confirm kubectl context

```bash
kubectl config current-context
# Should print your target cluster name, e.g. "my-eks-cluster"

kubectl get nodes -o wide
# Verify these are the nodes you intend to stress-test
```

### Step 2: Apply RBAC

The harness needs a ServiceAccount and ClusterRole for probe pods. `run.sh` applies this automatically, but you can apply it ahead of time to verify permissions:

```bash
kubectl apply -f v0/manifests/probe-rbac.yaml
```

This creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, and a ClusterRole granting read access to `/readyz`, nodes, and configmaps.

### Step 3: Run the harness

With default parameters (`v0/config.yaml`):

```bash
v0/run.sh
```

With a custom config file:

```bash
CONFIG_FILE=v0/configs/eks-small.yaml v0/run.sh
```

With environment variable overrides (highest precedence):

```bash
export RAMP_STEPS=3
export RAMP_CPU_REPLICAS=2
export RAMP_CPU_MILLICORES=250
export RAMP_MEM_MB=128
v0/run.sh
```

### Step 4: Verify artifacts

The run directory is printed at the start and end of every run:

```bash
# Find the latest run
ls -dt v0/runs/*/ | head -1

# Check contents
RUN_DIR=$(ls -dt v0/runs/*/ | head -1)
cat "$RUN_DIR/kb-version.txt"
cat "$RUN_DIR/phases.jsonl"
wc -l "$RUN_DIR/probe.jsonl"
cat "$RUN_DIR/summary.csv"
```

## Dry run (local Kind cluster)

Use this workflow for local smoke testing. This is the only workflow that requires Kind.

### Prerequisites

- `kubectl`
- `kind` (only for this section)

### Run the smoke test

```bash
v0/scripts/kind-smoke.sh
```

This single command will:
1. Create (or reuse) a Kind cluster named `kb-smoke`
2. Auto-download kube-burner v2.4.0 if not already present
3. Apply RBAC and run the full baseline -> ramp -> teardown -> recovery sequence
4. Assert that all expected artifacts exist and contain the right phases
5. Print PASS/FAIL and clean up the Kind cluster if it created one

The smoke test uses intentionally small parameter values (1 ramp step, 10s probes) to finish quickly.

## Configuration

### `config.yaml`

Flat YAML file of default parameters. Each key is uppercased and exported as an env var (e.g., `ramp_steps: 2` becomes `RAMP_STEPS=2`). Environment variables take precedence over the config file.

| Key | Default | Description |
|-----|---------|-------------|
| `baseline_probe_duration` | `10` | Seconds to run the baseline probe |
| `baseline_probe_interval` | `2` | Seconds between probe iterations |
| `ramp_steps` | `2` | Number of incremental stress steps |
| `ramp_cpu_replicas` | `1` | CPU-stress Deployments per step |
| `ramp_cpu_millicores` | `50` | CPU request/limit per stress pod (millicores) |
| `ramp_mem_replicas` | `1` | Memory-stress Deployments per step |
| `ramp_mem_mb` | `32` | Memory request/limit per stress pod (Mi) |
| `recovery_probe_duration` | `10` | Seconds to run the recovery probe |
| `recovery_probe_interval` | `2` | Seconds between recovery probe iterations |
| `kb_timeout` | `5m` | kube-burner per-phase timeout |

To use a custom config file without editing the defaults:

```bash
CONFIG_FILE=v0/configs/eks-small.yaml v0/run.sh
```

### Use a custom kube-burner binary

```bash
# Must be v2.4.0 (enforced by default)
KB_BIN=/usr/local/bin/kube-burner v0/run.sh

# Skip version check
KB_BIN=/path/to/custom-build KB_ALLOW_ANY=1 v0/run.sh
```

### Build kube-burner from source (optional)

```bash
# Requires Go >= 1.23 and a local kube-burner source checkout
bash v0/scripts/build-kube-burner.sh
```

## Common gotchas

**RBAC already applied automatically.** `run.sh` runs `kubectl apply -f v0/manifests/probe-rbac.yaml` at the start of every run. You do not need to apply it manually, but doing so before the first run is a good way to verify you have the right permissions. If you see permission errors, check that your kubeconfig identity can create namespaces, serviceaccounts, and clusterroles.

**kube-burner version must be v2.4.0.** The harness pins kube-burner v2.4.0 and enforces this on all resolution paths. If you set `KB_BIN` to a binary that reports a different version, `run.sh` will refuse to start. Set `KB_ALLOW_ANY=1` to bypass the version check if you know what you are doing.

**Templates are resolved relative to `v0/`.** `run.sh` changes directory to `v0/` before invoking kube-burner, so the relative template paths in `workloads/*.yaml` resolve correctly. Always invoke the harness as `v0/run.sh` from the repo root, or `./run.sh` from inside `v0/`.

**Probe pods need internet access to pull images.** The probe Job uses `bitnami/kubectl:latest`. In air-gapped clusters, pre-pull or mirror this image and update `v0/templates/probe-job.yaml`. The stress pods use `busybox:1.36.1`.

## Run artifacts

Each run creates `v0/runs/YYYYMMDD-HHMMSS/` containing:

- **`kb-version.txt`** -- Binary path and full version output
- **`phases.jsonl`** -- One JSON line per phase: `{"phase", "uuid", "rc", "start", "end", "elapsed_s"}`
- **`probe.jsonl`** -- One JSON line per probe check: `{"ts", "phase", "probe", "latency_ms", "exit_code", "seq"}`
- **`summary.csv`** -- Human-readable CSV of phase results
- **`phase-*.log`** -- Raw kube-burner output for each phase

## Folder structure

```
v0/
├── run.sh                          # Main harness entrypoint
├── config.yaml                     # Default parameters (overridable via env)
├── .gitignore                      # Ignores bin/, runs/, logs, collected-metrics/
│
├── bin/                            # Auto-populated (gitignored)
│   ├── kube-burner                 #   Downloaded binary
│   └── .kb-version                 #   Version stamp file
│
├── configs/                        # Custom config files
│   └── eks-small.yaml              #   Small EKS test parameters
│
├── scripts/
│   ├── kind-smoke.sh               # End-to-end smoke test (Kind + harness + assertions)
│   ├── install-kube-burner.sh      # Downloads kube-burner v2.4.0 from GitHub Releases
│   ├── build-kube-burner.sh        # OPTIONAL: build from source (requires Go >= 1.23)
│   └── summarize.sh                # Generates summary.csv from phases.jsonl
│
├── workloads/                      # kube-burner job definitions
│   ├── probe.yaml                  #   Probe phase (creates a kubectl Job)
│   └── ramp-step.yaml              #   Ramp phase (creates cpu + mem stress Deployments)
│
├── templates/                      # Kubernetes object templates (Go-templated)
│   ├── probe-job.yaml              #   Job that polls /readyz, list-nodes, list-configmaps
│   ├── cpu-stress.yaml             #   Deployment: busybox infinite CPU loop
│   └── mem-stress.yaml             #   Deployment: busybox dd into /dev/shm
│
├── manifests/
│   └── probe-rbac.yaml             # Namespace, ServiceAccount, ClusterRole for probes
│
└── runs/                           # Timestamped run artifact directories (gitignored)
    └── YYYYMMDD-HHMMSS/
        ├── kb-version.txt          #   Binary path + version output
        ├── phases.jsonl            #   One JSON object per phase (rc, elapsed, uuid)
        ├── probe.jsonl             #   Probe measurements (latency, exit code, seq)
        ├── summary.csv             #   CSV summary of all phases
        └── phase-*.log             #   Per-phase kube-burner stdout/stderr
```

## File reference

### `run.sh`

The main entrypoint. Resolves the kube-burner binary, applies RBAC, parses `config.yaml`, then orchestrates the four-phase sequence. All artifacts are collected into a timestamped `runs/` directory, even on failure.

**kube-burner resolution order:**
1. `KB_BIN` env var (must be executable; version-checked against v2.4.0 unless `KB_ALLOW_ANY=1`)
2. System `kube-burner` in `$PATH` (only if it reports v2.4.0)
3. `v0/bin/kube-burner` (auto-downloaded via `install-kube-burner.sh` if missing)

### `scripts/kind-smoke.sh`

Self-contained smoke test for **local dry runs only**. Creates a Kind cluster (or reuses an existing one named `kb-smoke`), runs the harness with small parameter values, then asserts that all expected artifacts exist and contain the right phases. Cleans up the cluster on exit if it created one.

### `scripts/install-kube-burner.sh`

Downloads kube-burner v2.4.0 from GitHub Releases for the current OS/arch (`darwin`/`linux` + `amd64`/`arm64`). Tries multiple known asset name patterns until one succeeds. After extracting, verifies the binary reports v2.4.0 and writes a stamp file to `v0/bin/.kb-version`.

### `scripts/build-kube-burner.sh`

**Optional.** Builds kube-burner from a local source checkout using Go >= 1.23. Not called automatically by any script. Use only if you need a custom build.

### `scripts/summarize.sh`

Parses `phases.jsonl` from a run directory and writes a `summary.csv` with columns: `phase, uuid, exit_code, start_epoch, end_epoch, elapsed_seconds, status`.

### `workloads/probe.yaml`

kube-burner job definition for the probe phase. Creates a single Kubernetes Job (from `templates/probe-job.yaml`) that runs kubectl commands in a loop to measure API latency.

### `workloads/ramp-step.yaml`

kube-burner job definition for each ramp step. Creates CPU-stress and memory-stress Deployments (from the corresponding templates) in a per-step namespace.

### `templates/probe-job.yaml`

Kubernetes Job template. Runs a shell loop inside a `bitnami/kubectl` container that performs three checks per iteration (`/readyz`, list nodes, list configmaps) and emits one JSON line per check to stdout.

### `templates/cpu-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container with an infinite `while true; do :; done` loop, consuming a configurable amount of CPU.

### `templates/mem-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container that uses `dd` to fill `/dev/shm` with a configurable number of megabytes, then sleeps forever.

### `manifests/probe-rbac.yaml`

Creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, and a ClusterRole/ClusterRoleBinding granting read access to `/readyz`, nodes, and configmaps. Applied automatically by `run.sh`.
