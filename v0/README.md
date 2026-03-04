# v0 -- Kubernetes Control-Plane Load-Testing Harness

A self-contained harness that uses [kube-burner](https://github.com/kube-burner/kube-burner) to measure Kubernetes API-server responsiveness under configurable CPU, memory, disk, and network stress. No Go toolchain required -- the harness automatically downloads a pinned kube-burner release binary.

The harness works against **any** Kubernetes cluster your `kubectl` can reach -- EKS, GKE, AKS, on-prem, or a local Kind cluster for dry runs.

## How it works

The harness runs four phases in order:

```
BASELINE probe  ->  RAMP stress (N steps)  ->  TEARDOWN  ->  RECOVERY probe
```

- **Baseline probe** -- Deploys a Job that repeatedly queries the API server (`/readyz`, list nodes, list configmaps) and records latency. This establishes the "quiet" baseline.
- **Ramp steps** -- For each step, deploys stress workloads into isolated namespaces (`kb-stress-1`, `kb-stress-2`, ...) to put pressure on the cluster. Which stress types are active (CPU, memory, disk, network) is determined by the contention mode selection at the start of the run.
- **Teardown** -- Deletes all stress namespaces.
- **Recovery probe** -- Identical to baseline, measures how quickly the API server returns to normal latency.

Every phase is recorded to `phases.jsonl`, probe measurements go to `probe.jsonl`, and a CSV summary is generated. All artifacts land in a timestamped run directory under `v0/runs/`.

## Contention modes

The harness supports four contention modes, each independently enabled or disabled:

| Mode | What it does | Default (interactive) | Default (non-interactive) |
|------|-------------|----------------------|--------------------------|
| **cpu** | Infinite busy-loop pods consuming configurable millicores | on | on |
| **mem** | Pods that fill `/dev/shm` with configurable MB | on | on |
| **disk** | Pods that continuously write/delete files on an `emptyDir` volume | on | off |
| **network** | Pods that make continuous HTTPS requests to a configurable target | on | off |

All four modes use `busybox:1.36.1` and require no privileged pods, `NET_ADMIN` capabilities, or PVCs. Both container images (`busybox:1.36.1` and `bitnami/kubectl:latest`) are bundled in the repo as a tar archive and pre-loaded into the cluster automatically -- no registry access is needed by default.

### CLI flags

By default, `run.sh` runs **non-interactively** using `config.yaml` and environment variable defaults. Use flags to enable interactive prompts:

```
v0/run.sh              # non-interactive (default)
v0/run.sh -i           # fully interactive (modes + registry)
v0/run.sh -c           # prompt for contention mode selection/settings
v0/run.sh -r           # prompt for image registry redirect + pull secret
v0/run.sh -cr          # prompt for both
v0/run.sh -h           # show usage help
```

`NONINTERACTIVE=1` is still supported for backward compatibility and overrides any flags.

### Interactive mode (`-i` or `-c`)

When you run `v0/run.sh -i` (or `-c`), it prompts for each mode in order before starting the test sequence:

```
>>> Contention mode selection
Enable cpu contention? [Y/n]
Edit cpu settings for this run? [Y/n] n
Enable mem contention? [Y/n]
Edit mem settings for this run? [Y/n]
  MEM replicas per step [1]: 2
  MEM MB per pod [32]: 64
Enable disk contention? [Y/n]
Edit disk settings for this run? [Y/n] n
Enable network contention? [Y/n] n

>>> Contention modes:
    cpu     = on   (replicas=1, millicores=50)
    mem     = on   (replicas=2, mb=64)
    disk    = on   (replicas=1, mb=64)
    network = off  (replicas=1, target=kubernetes.default.svc, interval=0.5s)
```

All enable prompts default to **YES** (press Enter to accept). Settings show their current default in brackets; press Enter to keep the default or type a new value.

### Registry redirect (`-i` or `-r`)

When you run `v0/run.sh -i` (or `-r`), the harness prompts for image registry redirects (useful for air-gapped clusters or private registries). If any images are redirected, it also asks for an optional `imagePullSecrets` name -- the Secret is injected into all pod specs so kubelet can authenticate to the private registry. You are responsible for creating the Secret in the target namespaces beforehand (e.g., via `kubectl create secret docker-registry`).

### Non-interactive overrides

In non-interactive mode (default), use environment variables to control behavior:

```bash
# Enable extra contention modes
MODE_DISK=on MODE_NETWORK=on v0/run.sh

# Redirect images via a map file and supply a pull secret
IMAGE_MAP_FILE=my-images.txt IMAGE_PULL_SECRET=my-registry-creds v0/run.sh
```

### Mode-specific settings

Each mode has tunable parameters, settable via interactive prompts, `config.yaml`, or environment variables:

**CPU:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_CPU_REPLICAS` | `1` |
| Millicores per pod | `RAMP_CPU_MILLICORES` | `50` |

**Memory:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_MEM_REPLICAS` | `1` |
| MB per pod | `RAMP_MEM_MB` | `32` |

**Disk:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_DISK_REPLICAS` | `1` |
| MB to write per pod | `RAMP_DISK_MB` | `64` |

Disk stress uses `dd` to write/delete files on an `emptyDir` volume. No PVCs or StorageClasses required.

**Network:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_NET_REPLICAS` | `1` |
| Target host | `RAMP_NET_TARGET` | `kubernetes.default.svc` |
| Request interval (seconds) | `RAMP_NET_INTERVAL` | `0.5` |

Network stress uses `wget` to make HTTPS requests to the target. The default target is the cluster's own API server via its in-cluster service DNS.

## Preflight

Before running the harness, confirm your environment:

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

With default parameters (`v0/config.yaml`), non-interactive:

```bash
v0/run.sh
```

Fully interactive (contention modes + registry redirect prompts):

```bash
v0/run.sh -i
```

Interactive for contention modes only:

```bash
v0/run.sh -c
```

With a custom config file:

```bash
CONFIG_FILE=v0/configs/eks-small.yaml v0/run.sh
```

With environment variable overrides (highest precedence):

```bash
RAMP_STEPS=3 RAMP_CPU_REPLICAS=2 RAMP_CPU_MILLICORES=250 MODE_DISK=on v0/run.sh
```

### Step 4: Verify artifacts

The run directory is printed at the start and end of every run:

```bash
# Find the latest run
ls -dt v0/runs/*/ | head -1

# Check contents
RUN_DIR=$(ls -dt v0/runs/*/ | head -1)
cat "$RUN_DIR/kb-version.txt"
cat "$RUN_DIR/modes.env"
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
3. Run the harness with `NONINTERACTIVE=1` (CPU and memory on, disk and network off)
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
| `ramp_probe_duration` | `10` | Seconds to probe during each ramp step |
| `ramp_probe_interval` | `2` | Seconds between ramp-step probe iterations |
| `recovery_probe_duration` | `10` | Seconds to run the recovery probe |
| `recovery_probe_interval` | `2` | Seconds between recovery probe iterations |
| `kb_timeout` | `5m` | kube-burner per-phase timeout |

### Contention mode variables

These control which stress modes are active and their parameters. They can be set via environment variables or `config.yaml`. In interactive mode the enable/disable prompts override the `MODE_*` values; in non-interactive mode (`NONINTERACTIVE=1`) these variables are used directly.

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE_CPU` | `on` | Enable CPU contention |
| `MODE_MEM` | `on` | Enable memory contention |
| `MODE_DISK` | `off` | Enable disk contention |
| `MODE_NETWORK` | `off` | Enable network contention |
| `RAMP_DISK_REPLICAS` | `1` | Disk-stress Deployments per step |
| `RAMP_DISK_MB` | `64` | MB to write per disk-stress pod |
| `RAMP_NET_REPLICAS` | `1` | Network-stress Deployments per step |
| `RAMP_NET_TARGET` | `kubernetes.default.svc` | Target host for network requests |
| `RAMP_NET_INTERVAL` | `0.5` | Seconds between network requests per pod |
| `IMAGE_PULL_SECRET` | *(empty)* | Kubernetes Secret name for private registry auth (injected into all pod specs) |
| `SKIP_IMAGE_LOAD` | `0` | Set to `1` to skip loading the bundled image tar into the cluster |

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

**RBAC already applied automatically.** `run.sh` runs `kubectl apply -f manifests/probe-rbac.yaml` at the start of every run. You do not need to apply it manually, but doing so before the first run is a good way to verify you have the right permissions. If you see permission errors, check that your kubeconfig identity can create namespaces, serviceaccounts, and clusterroles.

**kube-burner version must be v2.4.0.** The harness pins kube-burner v2.4.0 and enforces this on all resolution paths. If you set `KB_BIN` to a binary that reports a different version, `run.sh` will refuse to start. Set `KB_ALLOW_ANY=1` to bypass the version check if you know what you are doing.

**Templates are staged per run.** `run.sh` copies templates, workloads, and manifests into a staging directory (`$RUN_DIR/staging/`) before each run. The staged `ramp-step.yaml` is generated to include only the enabled contention modes, and any image rewrites are applied to the staged copies. This keeps every run fully isolated from source files and from other runs.

**Images are bundled and pre-loaded automatically.** Both images (`busybox:1.36.1` and `bitnami/kubectl:latest`) are shipped as `v0/images/harness-images.tar` and loaded into the cluster at the start of every run. No registry access is needed by default. All templates use `imagePullPolicy: IfNotPresent` so kubelet uses the pre-loaded images. To skip the automatic load (e.g., images are already on the nodes), set `SKIP_IMAGE_LOAD=1`. To use different images or a private registry instead, pass `-r` or set `IMAGE_MAP_FILE`. To refresh the bundled tar (e.g., after a kubectl version bump), run `scripts/save-images.sh` (requires Docker).

**Disk stress uses emptyDir.** The disk contention mode writes to an `emptyDir` volume, which is backed by the node's filesystem. No PVCs or StorageClasses are required. Write sizes are conservative by default (64 MB).

**Network stress does not require privileged pods.** The network contention mode uses `wget` to generate HTTPS traffic rather than `tc netem`, so no `NET_ADMIN` capability is needed. It runs on any cluster without special permissions.

## Run artifacts

Each run creates `v0/runs/YYYYMMDD-HHMMSS/` containing:

- **`kb-version.txt`** -- Binary path and full version output
- **`modes.env`** -- Human-readable KEY=VALUE record of selected contention modes and settings
- **`modes.json`** -- Machine-readable JSON of the same mode configuration
- **`phases.jsonl`** -- One JSON line per phase: `{"phase", "uuid", "rc", "start", "end", "elapsed_s"}`
- **`probe.jsonl`** -- One JSON line per probe check: `{"ts", "phase", "probe", "latency_ms", "exit_code", "seq"}`
- **`summary.csv`** -- Human-readable CSV of phase results
- **`phase-*.log`** -- Raw kube-burner output for each phase
- **`image-map.txt`** -- Image registry rewrites applied (or "(no rewrites)")
- **`staging/`** -- Staged copies of templates, workloads, and manifests used for this run

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
├── images/
│   └── harness-images.tar          # Bundled container images (busybox + kubectl)
│
├── scripts/
│   ├── kind-smoke.sh               # End-to-end smoke test (Kind + harness + assertions)
│   ├── install-kube-burner.sh      # Downloads kube-burner v2.4.0 from GitHub Releases
│   ├── build-kube-burner.sh        # OPTIONAL: build from source (requires Go >= 1.23)
│   ├── save-images.sh              # Pulls and saves container images to images/harness-images.tar
│   ├── load-images.sh              # Loads bundled images into the current cluster
│   └── summarize.sh                # Generates summary.csv from phases.jsonl
│
├── workloads/                      # kube-burner job definitions
│   ├── probe.yaml                  #   Probe phase (creates a kubectl Job)
│   └── ramp-step.yaml              #   Ramp phase (all four stress modes + probe)
│
├── templates/                      # Kubernetes object templates (Go-templated)
│   ├── probe-job.yaml              #   Job: polls /readyz, list-nodes, list-configmaps
│   ├── cpu-stress.yaml             #   Deployment: busybox infinite CPU loop
│   ├── mem-stress.yaml             #   Deployment: busybox dd into /dev/shm
│   ├── disk-stress.yaml            #   Deployment: busybox dd write/delete on emptyDir
│   └── net-stress.yaml             #   Deployment: busybox wget loop to target host
│
├── manifests/
│   └── probe-rbac.yaml             # Namespace, ServiceAccount, ClusterRole for probes
│
└── runs/                           # Timestamped run artifact directories (gitignored)
    └── YYYYMMDD-HHMMSS/
        ├── kb-version.txt          #   Binary path + version output
        ├── modes.env               #   Contention mode selection + settings (KEY=VALUE)
        ├── modes.json              #   Same as modes.env in JSON format
        ├── image-map.txt           #   Image registry rewrites (if any)
        ├── phases.jsonl            #   One JSON object per phase (rc, elapsed, uuid)
        ├── probe.jsonl             #   Probe measurements (latency, exit code, seq)
        ├── summary.csv             #   CSV summary of all phases
        ├── phase-*.log             #   Per-phase kube-burner stdout/stderr
        └── staging/                #   Staged templates/workloads/manifests for this run
```

## File reference

### `run.sh`

The main entrypoint. Accepts `-i` (full interactive), `-c` (contention mode prompts), `-r` (registry redirect prompts), or no flags (non-interactive default). Resolves the kube-burner binary, parses `config.yaml`, stages templates into the run directory, generates a filtered `ramp-step.yaml` containing only the enabled modes, optionally applies image registry rewrites and `imagePullSecrets`, applies RBAC, then orchestrates the four-phase sequence. All artifacts are collected into a timestamped `runs/` directory, even on failure.

**kube-burner resolution order:**
1. `KB_BIN` env var (must be executable; version-checked against v2.4.0 unless `KB_ALLOW_ANY=1`)
2. System `kube-burner` in `$PATH` (only if it reports v2.4.0)
3. `v0/bin/kube-burner` (auto-downloaded via `install-kube-burner.sh` if missing)

### `scripts/kind-smoke.sh`

Self-contained smoke test for **local dry runs only**. Creates a Kind cluster (or reuses an existing one named `kb-smoke`), runs the harness with `NONINTERACTIVE=1` and small parameter values, then asserts that all expected artifacts exist and contain the right phases. Cleans up the cluster on exit if it created one.

### `scripts/install-kube-burner.sh`

Downloads kube-burner v2.4.0 from GitHub Releases for the current OS/arch (`darwin`/`linux` + `amd64`/`arm64`). Tries multiple known asset name patterns until one succeeds. After extracting, verifies the binary reports v2.4.0 and writes a stamp file to `v0/bin/.kb-version`.

### `scripts/build-kube-burner.sh`

**Optional.** Builds kube-burner from a local source checkout using Go >= 1.23. Not called automatically by any script. Use only if you need a custom build.

### `scripts/save-images.sh`

Pulls `busybox:1.36.1` and `bitnami/kubectl:latest` via Docker and saves them into `v0/images/harness-images.tar`. Run this to refresh the bundled images (e.g., after a kubectl version bump). Requires Docker.

### `scripts/load-images.sh`

Loads `v0/images/harness-images.tar` into the current cluster. Auto-detects Kind (via kubectl context), k3d, or falls back to `docker load`. Called automatically by `run.sh` unless `-r`, `IMAGE_MAP_FILE`, or `SKIP_IMAGE_LOAD=1` is set.

### `scripts/summarize.sh`

Parses `phases.jsonl` from a run directory and writes a `summary.csv` with columns: `phase, uuid, exit_code, start_epoch, end_epoch, elapsed_seconds, status`.

### `workloads/probe.yaml`

kube-burner job definition for the probe phase. Creates a single Kubernetes Job (from `templates/probe-job.yaml`) that runs kubectl commands in a loop to measure API latency.

### `workloads/ramp-step.yaml`

kube-burner job definition for each ramp step. The checked-in file references all four stress templates (CPU, memory, disk, network) plus the probe job. At runtime, `run.sh` generates a filtered copy in staging that includes only the enabled modes' objects.

### `templates/probe-job.yaml`

Kubernetes Job template. Runs a shell loop inside a `bitnami/kubectl` container that performs three checks per iteration (`/readyz`, list nodes, list configmaps) and emits one JSON line per check to stdout.

### `templates/cpu-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container with an infinite `while true; do :; done` loop, consuming a configurable amount of CPU (millicores).

### `templates/mem-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container that uses `dd` to fill `/dev/shm` with a configurable number of megabytes, then sleeps forever.

### `templates/disk-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container that continuously writes and deletes files on an `emptyDir` volume using `dd`. Write size is configurable via the `diskMb` input variable. No PVC or privileged mode required.

### `templates/net-stress.yaml`

Kubernetes Deployment template. Runs a `busybox` container that makes continuous `wget` HTTPS requests to a configurable target host at a configurable interval. No privileged mode or `NET_ADMIN` capability required. The default target (`kubernetes.default.svc`) is the cluster's own API server.

### `manifests/probe-rbac.yaml`

Creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, and a ClusterRole/ClusterRoleBinding granting read access to `/readyz`, nodes, and configmaps. Applied automatically by `run.sh`.
