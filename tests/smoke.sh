#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$root/setup.sh" "$root/entrypoint.sh"
# The installer must remain project-agnostic. No repository names or
# benchmark-specific CPU policies may change defaults based on the URL.
if grep -Eq 'infocyph|foundation4|Foundation 4|owner_and_repo.*== ' "$root/setup.sh"; then
    printf '%s\n' 'FAILED: repository-specific installer behavior detected' >&2
    exit 1
fi
[[ "$(grep -c 'REPOSITORY_URL="${REPOSITORY_URL:-}"' "$root/setup.sh")" == 1 ]]
[[ "$(grep -c 'STRICT_CPU_ISOLATION="${STRICT_CPU_ISOLATION:-no}"' "$root/setup.sh")" == 1 ]]
[[ "$(grep -c 'RUNNER_NETWORK="${RUNNER_NETWORK:-bridge}"' "$root/setup.sh")" == 1 ]]
grep -q -- '--network "$RUNNER_NETWORK"' "$root/setup.sh"
"$root/setup.sh" help >/dev/null
"$root/setup.sh" doctor >/dev/null

# Regression: source the installer functions and exercise Docker argument
# construction under `set -u`. This previously failed with `name: unbound
# variable` because `local name=... home="...${name}"` expands together.
export SETUP_FILE="$root/setup.sh"
bash -euo pipefail -c '
    source <(sed "/^case \"\$MODE\" in/,$ d" "$SETUP_FILE")
    RUNNER_ROOT=/opt/github-actions-runners
    docker_host_args smoke-worker
    [[ "${CONTAINER_ARGS[0]}" == "--mount" ]]
    [[ "${CONTAINER_ARGS[1]}" == "type=bind,src=/opt/github-actions-runners/smoke-worker,dst=/opt/github-actions-runners/smoke-worker" ]]
    [[ "${CONTAINER_ARGS[3]}" == "RUNNER_HOME=/opt/github-actions-runners/smoke-worker" ]]
'

# Test general-purpose CPU settings without any repository-specific policy.
# A single pinned CPU is allowed for CI, and empty pinning is the default.
export SETUP_FILE="$root/setup.sh"
bash -euo pipefail -c '
    eval "$(sed -n "/^validate_cpu_set() {/,/^}/p" "$SETUP_FILE")"
    err() { printf "%s\n" "$*" >&2; exit 1; }
    say() { :; }
    CPU_SET=3; STRICT_CPU_ISOLATION=no; validate_cpu_set
    CPU_SET=0-3; STRICT_CPU_ISOLATION=no; validate_cpu_set
    CPU_SET=""; STRICT_CPU_ISOLATION=no; validate_cpu_set
    CPU_SET=1,4,7; STRICT_CPU_ISOLATION=no; validate_cpu_set
    CPU_SET=oops; STRICT_CPU_ISOLATION=no
    if (validate_cpu_set) >/dev/null 2>&1; then exit 1; fi
'


# Regression: isolation validation must inspect ONLINE SMT siblings, not only
# static sibling topology. Exercise with deterministic fake sysfs fixtures.
# These checks do not alter host CPU state.
bash -euo pipefail -c '
    eval "$(sed -n "/^validate_cpu_set() {/,/^}/p" "$SETUP_FILE")"
    err() { printf "validation rejected: %s\n" "$*" >&2; exit 1; }
    say() { :; }
    CPU_SYS_ROOT="$(mktemp -d)"
    trap "rm -rf $CPU_SYS_ROOT" EXIT
    for cpu in 0 1 2 3; do
        mkdir -p "$CPU_SYS_ROOT/cpu${cpu}/topology" "$CPU_SYS_ROOT/cpu$((cpu+8))"
        printf "%s\n" "$cpu" > "$CPU_SYS_ROOT/cpu${cpu}/topology/core_id"
        printf "%s\n" 0 > "$CPU_SYS_ROOT/cpu${cpu}/topology/physical_package_id"
        printf "%s,%s\n" "$cpu" "$((cpu+8))" > "$CPU_SYS_ROOT/cpu${cpu}/topology/thread_siblings_list"
        printf "%s\n" 1 > "$CPU_SYS_ROOT/cpu${cpu}/online"
        printf "%s\n" 0 > "$CPU_SYS_ROOT/cpu$((cpu+8))/online"
    done
    CPU_SET=0-3; STRICT_CPU_ISOLATION=yes; validate_cpu_set
    printf "%s\n" 1 > "$CPU_SYS_ROOT/cpu8/online"
    if (validate_cpu_set) >/dev/null 2>&1; then echo "FAILED: online SMT sibling accepted" >&2; exit 1; fi
    printf "%s\n" 0 > "$CPU_SYS_ROOT/cpu8/online"
    printf "%s\n" 0 > "$CPU_SYS_ROOT/cpu1/topology/core_id"
    if (validate_cpu_set) >/dev/null 2>&1; then echo "FAILED: duplicate physical core accepted" >&2; exit 1; fi
    printf "%s\n" 1 > "$CPU_SYS_ROOT/cpu1/topology/core_id"
    printf "%s\n" 0 > "$CPU_SYS_ROOT/cpu2/online"
    if (validate_cpu_set) >/dev/null 2>&1; then echo "FAILED: offline selected CPU accepted" >&2; exit 1; fi
    printf "%s\n" 1 > "$CPU_SYS_ROOT/cpu2/online"
    CPU_SET=0,0
    if (validate_cpu_set) >/dev/null 2>&1; then echo "FAILED: duplicate selected CPU accepted" >&2; exit 1; fi
    CPU_SET=0,2; validate_cpu_set
'

mkdir -p "$tmp/dist" "$tmp/home"
cat > "$tmp/dist/config.sh" <<'RUNNER_CONFIG'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == remove ]]; then
    rm -f .runner
else
    touch .runner
fi
RUNNER_CONFIG
cat > "$tmp/dist/run.sh" <<'RUNNER_START'
#!/usr/bin/env bash
printf 'runner-started\n'
RUNNER_START
chmod +x "$tmp/dist/config.sh" "$tmp/dist/run.sh"

export RUNNER_HOME="$tmp/home"
export RUNNER_DISTRIBUTION="$tmp/dist"
export GITHUB_REPOSITORY=https://github.com/example/library
export RUNNER_NAME=test-worker
export RUNNER_LABELS=sample-label

printf 'test-registration-token\n' | "$root/entrypoint.sh" register
[[ -f "$tmp/home/.runner" ]]
[[ "$("$root/entrypoint.sh" start)" == runner-started ]]
if printf 'test-registration-token\n' | "$root/entrypoint.sh" register >/dev/null 2>&1; then
    printf '%s\n' 'FAILED: duplicate registration was accepted' >&2
    exit 1
fi
printf 'test-removal-token\n' | "$root/entrypoint.sh" unregister
[[ ! -e "$tmp/home/.runner" ]]
if "$root/entrypoint.sh" start >/dev/null 2>&1; then
    printf '%s\n' 'FAILED: unregistered runner was started' >&2
    exit 1
fi

printf '%s\n' 'PASS: bash syntax, help/doctor, nounset, generic settings, online/offline SMT topology, duplicate guards, registration and removal'

# Per-runner settings must persist inside the project, never under the old
# system path, and must be parsed as data rather than executed as shell code.
export SETUP_FILE="$root/setup.sh"
export TEMP_RUNNER_TEST_ROOT="$tmp/project"
mkdir -p "$TEMP_RUNNER_TEST_ROOT/runners/alpha"
bash -euo pipefail -c '
    source <(sed "/^case \"\$MODE\" in/,$ d" "$SETUP_FILE")
    RUNNER_ROOT="$TEMP_RUNNER_TEST_ROOT/runners"
    RUNNER_NAME=alpha
    REPOSITORY_URL=https://github.com/example/alpha
    RUNNER_LABELS=perf,linux
    CPU_SET=0-3
    STRICT_CPU_ISOLATION=yes
    RUNNER_NETWORK=host
    write_runner_config
    [[ -f "$RUNNER_ROOT/alpha/runner.conf" ]]
    [[ "$(stat -c %a "$RUNNER_ROOT/alpha/runner.conf")" == 600 ]]
    REPOSITORY_URL=; RUNNER_LABELS=; CPU_SET=; STRICT_CPU_ISOLATION=; RUNNER_NETWORK=
    load_runner_config alpha
    [[ "$SAVED_REPOSITORY_URL" == https://github.com/example/alpha ]]
    [[ "$SAVED_RUNNER_LABELS" == perf,linux ]]
    [[ "$SAVED_CPU_SET" == 0-3 ]]
    [[ "$SAVED_STRICT_CPU_ISOLATION" == yes ]]
    [[ "$SAVED_RUNNER_NETWORK" == host ]]
    mkdir -p "$RUNNER_ROOT/beta"
    # A runner.conf value must never be executed or sourced.
    printf "RUNNER_NETWORK=host\nMALICIOUS=\$(touch %s/executed)\n" "$TEMP_RUNNER_TEST_ROOT" > "$RUNNER_ROOT/beta/runner.conf"
    if (load_runner_config beta) >/dev/null 2>&1; then echo "FAILED: unrecognized config accepted" >&2; exit 1; fi
    [[ ! -e "$TEMP_RUNNER_TEST_ROOT/executed" ]]
'

# The credentials and workspace must be gitignored AND outside Docker build
# context so they cannot leak into a Git commit or container image.
! grep -Eq 'LEGACY_RUNNER_ROOT|migrate_runner\(\)|migrate\) migrate_runner' "$root/setup.sh"
grep -q '^/runners/$' "$root/.gitignore"
grep -qx 'runners' "$root/.dockerignore"

printf '%s\n' 'PASS: project-local persistent configs and no config execution'
