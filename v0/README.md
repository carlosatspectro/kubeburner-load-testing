# v0 -- Kubernetes Control-Plane Load-Testing Harness

A self-contained harness that uses [kube-burner](https://github.com/kube-burner/kube-burner) to measure Kubernetes API-server responsiveness under incremental CPU and memory stress. No Go toolchain required -- the harness automatically downloads a pinned kube-burner release binary.

## Quick start

```bash
# Prerequisites: kind, kubectl
v0/scripts/kind-smoke.sh
```

This single command will:
1. Create (or reuse) a Kind cluster
2. Auto-download kube-burner v2.4.0 if not already present
3. Run the full baseline -> ramp -> teardown -> recovery sequence
4. Verify all artifacts and print PASS/FAIL

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

The main entrypoint. Resolves the kube-burner binary, parses `config.yaml`, then orchestrates the four-phase sequence. All artifacts are collected into a timestamped `runs/` directory, even on failure.

**kube-burner resolution order:**
1. `KB_BIN` env var (must be executable; version-checked against v2.4.0 unless `KB_ALLOW_ANY=1`)
2. System `kube-burner` in `$PATH` (only if it reports v2.4.0)
3. `v0/bin/kube-burner` (auto-downloaded via `install-kube-burner.sh` if missing)

### `config.yaml`

Flat YAML file of default parameters. Each key is uppercased and exported as an env var (e.g., `ramp_steps: 2` becomes `RAMP_STEPS=2`). Environment variables take precedence.

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

### `scripts/kind-smoke.sh`

Self-contained smoke test. Creates a Kind cluster (or reuses an existing one named `kb-smoke`), runs the harness with small parameter values, then asserts that all expected artifacts exist and contain the right phases. Cleans up the cluster on exit if it created one.

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

Creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, and a ClusterRole/ClusterRoleBinding granting read access to `/readyz`, nodes, and configmaps.

## Usage

### Run against any cluster

```bash
# Point kubectl at your target cluster, then:
v0/run.sh
```

### Run the Kind smoke test

```bash
v0/scripts/kind-smoke.sh
```

### Customize parameters

Via environment variables (highest precedence):

```bash
export RAMP_STEPS=5
export RAMP_CPU_MILLICORES=200
export RAMP_MEM_MB=128
v0/run.sh
```

Or edit `v0/config.yaml` for persistent defaults.

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

## Run artifacts

Each run creates `v0/runs/YYYYMMDD-HHMMSS/` containing:

- **`kb-version.txt`** -- Binary path and full version output
- **`phases.jsonl`** -- One JSON line per phase: `{"phase", "uuid", "rc", "start", "end", "elapsed_s"}`
- **`probe.jsonl`** -- One JSON line per probe check: `{"ts", "phase", "probe", "latency_ms", "exit_code", "seq"}`
- **`summary.csv`** -- Human-readable CSV of phase results
- **`phase-*.log`** -- Raw kube-burner output for each phase

## Prerequisites

- **kubectl** -- configured to reach your target cluster
- **kind** -- only needed for `kind-smoke.sh`
- **curl** -- for auto-downloading kube-burner
- No Go toolchain required for normal usage
