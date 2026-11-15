
# GitHub Actions Docker Runner

A reusable, Git-ready **GitHub Actions self-hosted runner installer** for Linux x64. It is **not tied to any repository, organization, job type, or benchmark**. A single copy can register multiple runners with different names, repositories, and custom labels.

`setup.sh` checks the host, installs Docker Engine where supported and missing, builds a checksum-verified runner image, prompts for a fresh registration token, registers the runner, starts it, and shows how to manage it. The script contains its own non-secret defaults at the top; it **never invokes `sudo` internally**.

## Install

```bash
unzip github-actions-docker-runner.zip
cd github-actions-docker-runner
./setup.sh doctor
sudo ./setup.sh
```

Answer the interactive prompts:

| Prompt                                                       | Default              | Description                                                                                           |
| ------------------------------------------------------------ | -------------------- | ----------------------------------------------------------------------------------------------------- |
| GitHub repository or organization URL                        | Required             | `https://github.com/OWNER/REPO` or `https://github.com/ORG`                                       |
| Unique runner name                                           | Generated            | Derived from the repository or organization and hostname                                              |
| Comma-separated custom labels                                | `docker-worker`    | Example: `ci,linux-docker`                                                                          |
| Pinned host CPUs                                             | Blank (unrestricted) | Optional Docker CPU list such as `0-3` or `0,2,4,6`                                               |
| Require distinct physical cores with no ONLINE SMT siblings? | `no`               | Optional, strict online-core isolation check, **not** required for normal CI                    |
| Runner Docker network mode                                   | `bridge`           | Use `host` only for Linux workflows that reach host-published Docker services via `127.0.0.1`     |
| Fresh GitHub runner registration token                       | Required             | Copy **only the token** from GitHub → Settings → Actions → Runners → New self-hosted runner |

**For ordinary CI:** leave CPU pinning blank and keep the SMT-sibling check at `no`. No benchmark requirements are imposed by the installer. Individual projects may apply stricter checks in their own workflows.

To run a second worker, execute `sudo ./setup.sh` again with a different unique runner name. Configure a different GitHub URL and label if appropriate. Do **not** operate competing CPU-intensive runners on a host reserved for reproducible performance testing.

## Persistent runner configuration in this directory

```
github-actions-docker-runner/
├── setup.sh
├── Dockerfile
├── entrypoint.sh
├── README.md
├── tests/
└── runners/                         # Git-ignored and excluded from Docker builds
    └── my-runner/
        ├── runner.conf               # Saved, non-secret prompt answers
        ├── .gha-installer-info       # GitHub URL and label identity
        ├── .runner                   # Live GitHub registration (sensitive)
        ├── .credentials              # Sensitive; never commit
        └── _work/                    # Job workspace
```

To reuse settings without typing the repository URL again:

```bash
sudo ./setup.sh setup my-runner
```

You can change the network and CPU answers while rerunning setup for a stopped runner. Enter `none` at the CPU prompt to clear a saved pin. Runner passwords and registration tokens are **never** written to `runner.conf`.

### Existing installations in another directory

There is **no automatic migration**. This installer only manages workers whose state is stored under its own `runners/` directory. Older installations outside this directory remain untouched. If an old container uses the same runner name, stop and unregister it using its original installer (or choose a new unique name) before registering a new runner here. A new runner registration requires a fresh GitHub registration token.

Keep the project directory at a stable absolute path: Docker workspaces and credentials are mounted from it. Do not move or reclone it while a runner is active.

## Service-container networking

A containerized runner normally uses Docker's `bridge` network, which isolates its `127.0.0.1` from the host Docker daemon. Workflows that publish PostgreSQL, Redis, or other service-container ports to the host and access them via `127.0.0.1` need `host` networking on a **trusted native Linux host**. Select `host` at setup when this is essential. Host networking reduces network isolation; never enable it for untrusted jobs.

To switch an **already registered** worker from `bridge` to `host`, first stop the worker after ensuring no job is active, then run setup again using **the same runner name, GitHub URL and labels**, choose `host` for network mode, and keep the existing credentials. Setup refuses to silently apply network or CPU changes to a running worker. The installer will recreate only the stopped container; it does not require a new token.

## Commands

```bash
sudo ./setup.sh status RUNNER_NAME
sudo ./setup.sh logs RUNNER_NAME
sudo ./setup.sh stop RUNNER_NAME
sudo ./setup.sh start RUNNER_NAME
sudo ./setup.sh remove RUNNER_NAME
sudo ./setup.sh setup RUNNER_NAME
./setup.sh doctor
```

`remove` stops the worker and requests a fresh GitHub removal token. It deliberately preserves the on-host runner directory for inspection. Recreating a registered container uses its persisted credentials; it does not require another registration token. Tokens are entered without echo and transmitted to the runner only via standard input, not saved in the Docker image, environment, command line of `docker run`, or on-disk token file.

## Reuse it as a Git repository

Commit the portable files: `Dockerfile`, `entrypoint.sh`, `setup.sh`, `README.md`, `.gitignore`, `.dockerignore`, and `tests/`. Do not commit runner credentials or token files. On a new host, clone/pull and run `sudo ./setup.sh`. Script settings may be modified at the top of `setup.sh` or supplied via environment variables if necessary; secrets are always prompted interactively.

**All runner state now lives in the checkout itself**, under the git-ignored `runners/RUNNER_NAME/` directory (override with `RUNNER_ROOT` if absolutely needed). That directory includes the registration credentials, job workspace, and a **`runner.conf`** containing only validated non-secret settings (repository, labels, network mode, CPU pinning and isolation flag). The installer reads this file as data, never runs it as shell code. Keep the directory access-restricted, never commit or upload it, and back it up securely if you need credentials preserved. The containerized runner and host Docker share the **same absolute workspace path**, required for Docker service containers and bind mounts. Pulling Git updates preserves ignored runner state; deleting/recloning the directory does not.

## Hardware isolation and machine restarts

Strict CPU-isolation checks are **opt-in** and do not change the Linux host. If enabled, each selected CPU must be online, correspond to a different physical core and have **no other online SMT sibling**. For example, a host with CPUs `0-3` paired with siblings `8-11` can pass only after `8-11` are taken offline or equivalent verified isolation is achieved. Offlining CPUs is a separate, host-wide administrative operation and is **not performed** by this installer. Changes to `/sys/devices/system/cpu/cpu*/online` normally do not persist across reboot; recheck host isolation before any strict benchmarks. A general-purpose runner does not need this mode.

Workers use Docker's `--restart unless-stopped` policy. It normally restarts a worker after a Docker daemon/host restart. If you deliberately stopped a worker, use `sudo ./setup.sh start NAME` to resume it. Runner credentials and workspaces remain under `RUNNER_ROOT` across container recreation; they must be protected.

## Hardware and software requirements

- **Native Linux x64 host** with Docker Engine (Ubuntu/Debian `docker.io` can be installed automatically if missing). Other Linux distributions require preinstalled Docker. Docker Desktop/Windows/macOS are not covered by the current script.
- **Pinned runner distribution:** `2.338.2`, verified by its SHA-256. If updating, update `RUNNER_VERSION` and `RUNNER_ARCHIVE_SHA256` (and matching Dockerfile defaults).
- **Optional CPU pinning** restricts the runner container, not the host's other processes. Opt-in CPU-isolation validation verifies different physical cores and rejects **online** SMT sibling threads. Hardware with SMT support is allowed when the sibling threads are offline. No host CPU state is modified.
- **Docker socket access** provides effectively root-level host control. The runner container also includes passwordless `sudo` for job compatibility. Use only on a dedicated or strongly isolated host, restrict repository permissions, and never run untrusted public pull-request workflows on it.
- For strict benchmarking or production-sensitive workloads, use independently qualified hosts and project-specific measurement gates. Successfully registering a runner does not certify its performance stability.

## Tests

```bash
bash -n setup.sh entrypoint.sh
bash tests/smoke.sh
```

These tests do not require Docker Engine or a GitHub token. The actual runner image build and GitHub registration require a real host and a valid token.
