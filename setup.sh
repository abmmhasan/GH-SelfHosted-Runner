#!/usr/bin/env bash
# Portable (across repositories) Linux Docker-based GitHub Actions runner setup.
# Run: sudo ./setup.sh       (no sudo command is invoked by this script)
# Existing runners: sudo ./setup.sh status|logs|start|stop|remove RUNNER_NAME
# Runner state and non-secret configuration live in ./runners/NAME/ by default.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ─── Configuration defaults; override with environment variables or prompts ───
REPOSITORY_URL="${REPOSITORY_URL:-}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
CPU_SET="${CPU_SET:-}"
STRICT_CPU_ISOLATION="${STRICT_CPU_ISOLATION:-no}" # Opt-in check for pinned CPUs only
RUNNER_NETWORK="${RUNNER_NETWORK:-bridge}" # bridge (normal CI) or host (localhost service workflows)
RUNNER_ROOT="${RUNNER_ROOT:-${SCRIPT_DIR}/runners}"
RUNNER_UID="${RUNNER_UID:-1001}"
RUNNER_GID="${RUNNER_GID:-1001}"
RUNNER_VERSION="${RUNNER_VERSION:-2.338.2}"
RUNNER_ARCHIVE_SHA256="${RUNNER_ARCHIVE_SHA256:-baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40}"
INSTALL_DOCKER="${INSTALL_DOCKER:-yes}"   # Install Docker on supported Debian/Ubuntu hosts if missing
# ───────────────────────────────────────────────────────────────────────────────

IMAGE="github-actions-runner:${RUNNER_VERSION}-uid${RUNNER_UID}-gid${RUNNER_GID}"
MODE="${1:-setup}"

say() { printf '\n\033[1;34m[gha-runner]\033[0m %s\n' "$*"; }
err() { printf '[gha-runner] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
GitHub Actions Linux Docker runner setup (one script for many repositories)

  sudo ./setup.sh                  Interactively configure and start a new runner
  sudo ./setup.sh setup [NAME]     Configure a new/existing named runner
  sudo ./setup.sh status NAME      Display a configured worker's container status
  sudo ./setup.sh logs NAME        Follow the container's logs
  sudo ./setup.sh start NAME       Start a previously registered worker
  sudo ./setup.sh stop NAME        Stop a worker (does not unregister it)
  sudo ./setup.sh remove NAME      Stop and unregister using a fresh removal token
  ./setup.sh doctor                Inspect host CPU and Docker availability
  ./setup.sh help                  Display this help

All non-secret defaults are defined at the TOP of this file and can be
supplied as environment variables before running the script. Interactive
setup prompts for repository URL, runner name, labels, CPU pinning,
and Docker network mode (bridge by default, host only when needed).

Registration/removal tokens are read securely and used once via stdin; they
are not written to disk, passed as Docker environment variables, or included
in the image. Credentials, workspace and non-secret saved runner.conf live
under ./runners/NAME by default (git-ignored). Never commit this directory.
HELP
}

require_linux() {
    [[ "$(uname -s)" == Linux ]] || err 'A native Linux Docker host is required.'
    [[ "$(uname -m)" == x86_64 ]] || err 'This bundled, checksum-pinned runner supports Linux x86_64 only.'
}

require_root() {
    [[ "$EUID" -eq 0 ]] || err 'Run: sudo ./setup.sh (setup needs root for Docker/host state).'
}

prompt() {
    local __variable="$1" label="$2" default="$3" response=''
    if [[ -t 0 ]]; then
        if [[ -n "$default" ]]; then
            read -r -p "${label} [${default}]: " response || true
        else
            read -r -p "${label}: " response || true
        fi
    fi
    printf -v "$__variable" '%s' "${response:-$default}"
}

secret_prompt() {
    local __variable="$1" label="$2" answer=''
    if [[ ! -t 0 ]]; then
        err 'A terminal is required to enter a fresh GitHub runner token securely.'
    fi
    read -r -s -p "${label}: " answer
    printf '\n'
    [[ -n "$answer" ]] || err 'Token cannot be empty.'
    printf -v "$__variable" '%s' "$answer"
    unset answer
}

validate_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || err "Invalid runner name: $1"
}

validate_host_directory() {
    [[ "$RUNNER_ROOT" == /* && "$RUNNER_ROOT" != / ]] || err 'RUNNER_ROOT must be a non-root absolute path.'
    [[ "$RUNNER_ROOT" != *$'\n'* && "$RUNNER_ROOT" != *:* ]] || err 'RUNNER_ROOT has unsupported characters.'
}

validate_repo_url() {
    [[ "$REPOSITORY_URL" =~ ^https://github\.com/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)?/?$ ]] \
        || err 'Repository URL must look like https://github.com/OWNER/REPO (or https://github.com/ORG).'
    REPOSITORY_URL="${REPOSITORY_URL%/}"
}

validate_labels() {
    RUNNER_LABELS="${RUNNER_LABELS// /}"
    [[ "$RUNNER_LABELS" =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]] \
        || err 'Runner labels must be comma-separated words (letters/numbers/._-).'
}

# Optional host check: selected logical CPUs must map to different physical
# cores, and none may have another ONLINE SMT sibling. SMT-capable hardware
# with its sibling threads offlined is valid. Does not modify host CPUs.
validate_cpu_set() {
    if [[ -n "$CPU_SET" ]]; then
        [[ "$CPU_SET" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] \
            || err 'CPU_SET must be a Docker CPU list, e.g. 0-3 or 0,2,4,6.'
    fi
    [[ "$STRICT_CPU_ISOLATION" == yes || "$STRICT_CPU_ISOLATION" == no ]] \
        || err 'STRICT_CPU_ISOLATION must be yes or no.'
    [[ "$STRICT_CPU_ISOLATION" == yes ]] || return 0
    [[ -n "$CPU_SET" ]] || err 'CPU_SET must be provided when isolation validation is enabled.'

    local cpu_root="${CPU_SYS_ROOT:-/sys/devices/system/cpu}"
    local part first last cpu core socket siblings range sibling online_file key sfirst slast
    local -a parts=() ranges=()
    local -A seen_cpu=() seen_core=()
    IFS=',' read -r -a parts <<< "$CPU_SET"
    say "Checking physical-core isolation for host CPUs: ${CPU_SET}"

    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            first="${part%%-*}"
            last="${part##*-}"
        else
            first="$part"
            last="$part"
        fi
        first=$((10#$first))
        last=$((10#$last))
        ((last >= first && last - first <= 512)) || err "Invalid or oversized CPU range: $part"

        for ((cpu=first; cpu<=last; cpu++)); do
            [[ ! -v 'seen_cpu[$cpu]' ]] || err "CPU $cpu is specified more than once."
            seen_cpu[$cpu]=1
            local topology="$cpu_root/cpu${cpu}/topology"
            [[ -r "$topology/core_id" && -r "$topology/physical_package_id" && -r "$topology/thread_siblings_list" ]] \
                || err "Missing CPU topology information for CPU $cpu."
            online_file="$cpu_root/cpu${cpu}/online"
            if [[ -r "$online_file" ]]; then
                [[ "$(< "$online_file")" == 1 ]] || err "Selected CPU $cpu is offline."
            fi
            core="$(< "$topology/core_id")"
            socket="$(< "$topology/physical_package_id")"
            key="${socket}_${core}"
            [[ ! -v 'seen_core[$key]' ]] || err "Selected CPUs share physical core $key."
            seen_core[$key]=1

            siblings="$(< "$topology/thread_siblings_list")"
            IFS=',' read -r -a ranges <<< "$siblings"
            for range in "${ranges[@]}"; do
                if [[ "$range" == *-* ]]; then
                    sfirst="${range%%-*}"
                    slast="${range##*-}"
                else
                    sfirst="$range"
                    slast="$range"
                fi
                [[ "$sfirst" =~ ^[0-9]+$ && "$slast" =~ ^[0-9]+$ ]] \
                    || err "Invalid sysfs siblings for CPU $cpu: $siblings"
                sfirst=$((10#$sfirst))
                slast=$((10#$slast))
                ((slast >= sfirst && slast - sfirst <= 512)) \
                    || err "Invalid sysfs siblings for CPU $cpu: $siblings"
                for ((sibling=sfirst; sibling<=slast; sibling++)); do
                    ((sibling == cpu)) && continue
                    [[ -d "$cpu_root/cpu${sibling}" ]] \
                        || err "Cannot verify sibling CPU $sibling of $cpu."
                    online_file="$cpu_root/cpu${sibling}/online"
                    [[ -r "$online_file" ]] \
                        || err "Cannot verify online state of sibling CPU $sibling."
                    [[ "$(< "$online_file")" != 1 ]] \
                        || err "CPU $cpu shares its physical core with ONLINE CPU $sibling."
                done
            done
            printf '  CPU %s: physical core %s; no online SMT siblings\n' "$cpu" "$key"
        done
    done
    say 'Physical-core isolation verified (does not guarantee benchmark stability).'
}


# Persist only known non-secret keys. Never source() this file: the same
# directory contains third-party runner state and must not execute its data.
load_runner_config() {
    local name="$1"
    local path="${RUNNER_ROOT}/${name}/runner.conf"
    local key value
    SAVED_REPOSITORY_URL='' SAVED_RUNNER_LABELS='' SAVED_CPU_SET=''
    SAVED_STRICT_CPU_ISOLATION='' SAVED_RUNNER_NETWORK=''
    [[ -f "$path" ]] || return 0
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            REPOSITORY_URL) SAVED_REPOSITORY_URL="$value" ;;
            RUNNER_LABELS) SAVED_RUNNER_LABELS="$value" ;;
            CPU_SET) SAVED_CPU_SET="$value" ;;
            STRICT_CPU_ISOLATION) SAVED_STRICT_CPU_ISOLATION="$value" ;;
            RUNNER_NETWORK) SAVED_RUNNER_NETWORK="$value" ;;
            ''|'#'*) ;;
            *) err "Unexpected key in stored runner configuration: $key" ;;
        esac
    done < "$path"
}

write_runner_config() {
    local home="${RUNNER_ROOT}/${RUNNER_NAME}"
    local target="${home}/runner.conf" tempfile
    tempfile="$(mktemp "${home}/.runner-conf.XXXXXX")"
    chmod 0600 "$tempfile"
    {
        printf 'REPOSITORY_URL=%s\n' "$REPOSITORY_URL"
        printf 'RUNNER_LABELS=%s\n' "$RUNNER_LABELS"
        printf 'CPU_SET=%s\n' "$CPU_SET"
        printf 'STRICT_CPU_ISOLATION=%s\n' "$STRICT_CPU_ISOLATION"
        printf 'RUNNER_NETWORK=%s\n' "$RUNNER_NETWORK"
    } > "$tempfile"
    mv -f -- "$tempfile" "$target"
}

prepare_runner_root() {
    mkdir -p -- "$RUNNER_ROOT"
    [[ ! -L "$RUNNER_ROOT" ]] || err 'Runner state directory must not be a symlink.'
    chmod 0700 "$RUNNER_ROOT"
}

install_docker_if_needed() {
    if ! command -v docker >/dev/null 2>&1; then
        [[ "$INSTALL_DOCKER" == yes ]] || err 'Docker is missing; install Docker Engine first.'
        [[ -f /etc/os-release ]] || err 'Docker installation is supported automatically only on Ubuntu/Debian.'
        # shellcheck disable=SC1091
        source /etc/os-release
        [[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] \
            || err 'Please install Docker Engine for this Linux distribution first.'
        say 'Installing Docker Engine from the operating-system package repository.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io ca-certificates
    fi

    if ! docker info >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now docker || true
        elif command -v service >/dev/null 2>&1; then
            service docker start || true
        fi
    fi
    docker info >/dev/null 2>&1 || err 'Docker daemon is not responding. Check the Docker service and socket.'
    [[ -S /var/run/docker.sock ]] || err 'Host Docker socket /var/run/docker.sock is missing.'
}

docker_host_args() {
    # Common runner environment. Workspace has the SAME absolute path in the
    # container and on the Docker host, so sibling service binds resolve.
    # Declare in separate statements: under `set -u`, Bash expands values in
    # the declaration before assigning `name` to the current shell scope.
    local name="$1"
    local home="${RUNNER_ROOT}/${name}"
    CONTAINER_ARGS=(
        --mount "type=bind,src=${home},dst=${home}"
        -e "RUNNER_HOME=${home}"
        --user "${RUNNER_UID}:${RUNNER_GID}"
    )
}

container_name() { printf 'gha-runner-%s' "$1"; }

existing_container() {
    docker container inspect "$(container_name "$1")" >/dev/null 2>&1
}

setup_runner() {
    require_root
    require_linux
    validate_host_directory

    say 'Configure a GitHub repository or organization runner.'
    # NAME can be supplied to reuse a saved config without retyping its URL.
    if [[ -n "${2:-}" ]]; then
        RUNNER_NAME="$2"
        validate_name "$RUNNER_NAME"
        load_runner_config "$RUNNER_NAME"
        REPOSITORY_URL="${REPOSITORY_URL:-${SAVED_REPOSITORY_URL:-}}"
    fi
    prompt REPOSITORY_URL 'GitHub URL (https://github.com/OWNER/REPO or ORG)' "$REPOSITORY_URL"
    validate_repo_url
    local owner_and_repo="${REPOSITORY_URL#https://github.com/}"
    local default_name
    default_name="$(printf '%s-%s' "${owner_and_repo//\//-}" "$(hostname -s)" \
        | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_.-' | cut -c 1-64)"

    prompt RUNNER_NAME 'Unique runner name (per host)' "${RUNNER_NAME:-$default_name}"
    validate_name "$RUNNER_NAME"
    load_runner_config "$RUNNER_NAME"
    if [[ -n "${SAVED_REPOSITORY_URL:-}" && "$SAVED_REPOSITORY_URL" != "$REPOSITORY_URL" ]]; then
        err "Saved runner $RUNNER_NAME belongs to $SAVED_REPOSITORY_URL, not $REPOSITORY_URL"
    fi
    prompt RUNNER_LABELS 'Comma-separated custom labels' "${RUNNER_LABELS:-${SAVED_RUNNER_LABELS:-docker-worker}}"
    prompt CPU_SET 'Optional pinned host CPUs (type none to clear)' "${CPU_SET:-${SAVED_CPU_SET:-}}"
    case "${CPU_SET,,}" in none|off|unrestricted|-) CPU_SET='' ;; esac
    prompt STRICT_CPU_ISOLATION 'Require pinned CPUs to have distinct physical cores with no ONLINE SMT siblings? (yes/no)' "${SAVED_STRICT_CPU_ISOLATION:-$STRICT_CPU_ISOLATION}"
    prompt RUNNER_NETWORK 'Runner Docker network mode (bridge/host)' "${SAVED_RUNNER_NETWORK:-$RUNNER_NETWORK}"

    validate_name "$RUNNER_NAME"
    validate_labels
    validate_cpu_set
    [[ "$RUNNER_NETWORK" == bridge || "$RUNNER_NETWORK" == host ]] \
        || err "RUNNER_NETWORK must be bridge or host."
    [[ "$RUNNER_UID" =~ ^[0-9]+$ && "$RUNNER_GID" =~ ^[0-9]+$ ]] || err 'Runner UID/GID must be numeric.'
    [[ "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || err 'Invalid RUNNER_VERSION.'
    [[ "$RUNNER_ARCHIVE_SHA256" =~ ^[a-f0-9]{64}$ ]] || err 'Runner SHA256 must be a 64-character lowercase hex digest.'

    local home="${RUNNER_ROOT}/${RUNNER_NAME}"
    local cname
    cname="$(container_name "$RUNNER_NAME")"
    install_docker_if_needed
    # Never overwrite a container registered by an older installation or
    # another checkout. No automatic migration or duplicate registration.
    if [[ ! -f "$home/.runner" ]] && existing_container "$RUNNER_NAME"; then
        err "A container already exists for $RUNNER_NAME but no registration is saved under $home. Stop/unregister the old runner separately or choose a new name."
    fi
    prepare_runner_root

    [[ ! -L "$home" ]] || err "Runner state path is a symlink: $home"
    mkdir -p "$home"
    chmod 0700 "$home"
    chown "$RUNNER_UID:$RUNNER_GID" "$home"
    mkdir -p "$home/_work"
    chown "$RUNNER_UID:$RUNNER_GID" "$home/_work"
    chmod 0700 "$home/_work"

    say "Building verified GitHub runner image ${IMAGE}."
    docker build --pull \
        --build-arg "RUNNER_VERSION=$RUNNER_VERSION" \
        --build-arg "RUNNER_ARCH=x64" \
        --build-arg "RUNNER_SHA256=$RUNNER_ARCHIVE_SHA256" \
        --build-arg "RUNNER_UID=$RUNNER_UID" \
        --build-arg "RUNNER_GID=$RUNNER_GID" \
        --tag "$IMAGE" \
        "$SCRIPT_DIR"

    docker_host_args "$RUNNER_NAME"
    local metadata="${home}/.gha-installer-info"
    if [[ -f "$home/.runner" ]]; then
        # Never silently reuse credentials registered against another GitHub
        # repository/organization or label set on this host.
        [[ -r "$metadata" ]] || err "Existing runner $RUNNER_NAME is untracked. Inspect $home before reusing that name."
        local -a saved_info
        mapfile -t saved_info < "$metadata"
        [[ "${saved_info[0]:-}" == "$REPOSITORY_URL" ]] || err \
            "Runner $RUNNER_NAME is registered to ${saved_info[0]:-unknown}; choose a unique name for another repository."
        [[ "${saved_info[1]:-}" == "$RUNNER_LABELS" ]] || err \
            "Existing runner labels differ (${saved_info[1]:-unknown}); unregister/recreate it to change labels."
    fi
    if [[ ! -f "$home/.runner" ]]; then
        local registration_token=''
        say 'Create a FRESH runner registration token under the selected GitHub repository/organization Settings > Actions > Runners.'
        printf '  Repository: %s\n' "$REPOSITORY_URL"
        secret_prompt registration_token 'Paste the new GitHub runner REGISTRATION token'
        say 'Registering runner without writing the registration token to disk.'
        printf '%s\n' "$registration_token" | docker run --rm -i \
            "${CONTAINER_ARGS[@]}" \
            -e "GITHUB_REPOSITORY=$REPOSITORY_URL" \
            -e "RUNNER_NAME=$RUNNER_NAME" \
            -e "RUNNER_LABELS=$RUNNER_LABELS" \
            "$IMAGE" register
        unset registration_token
        [[ -f "$home/.runner" ]] || err 'GitHub did not create a runner configuration.'
        printf '%s\n' "$REPOSITORY_URL" "$RUNNER_LABELS" > "$metadata"
        chown "$RUNNER_UID:$RUNNER_GID" "$metadata"
        chmod 0600 "$metadata"
    else
        say 'Existing runner configuration found; no new token or registration required.'
    fi

    if existing_container "$RUNNER_NAME"; then
        local current_status
        current_status="$(docker inspect -f '{{.State.Status}}' "$cname")"
        if [[ "$current_status" == running ]]; then
            local existing_network
            existing_network="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cname")"
            [[ "$existing_network" == "$RUNNER_NETWORK" ]] || err \
                "Runner is already running with network $existing_network; stop it first: ./setup.sh stop $RUNNER_NAME"
            local existing_cpus
            existing_cpus="$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$cname")"
            [[ "$existing_cpus" == "$CPU_SET" ]] || err \
                "Runner is already running with CPU set ${existing_cpus:-unrestricted}; stop it before changing CPU pinning."
            write_runner_config
            say "Runner ${RUNNER_NAME} is already running; no job has been interrupted."
            return
        fi
        docker rm -f "$cname" >/dev/null
    fi

    local docker_sock_group
    docker_sock_group="$(stat -c '%g' /var/run/docker.sock)"
    local cpu_args=()
    if [[ -n "$CPU_SET" ]]; then
        cpu_args+=(--cpuset-cpus "$CPU_SET")
    fi

    say "Launching ${RUNNER_NAME} on ${REPOSITORY_URL}."
    docker run --detach \
        --name "$cname" \
        --restart unless-stopped \
        --network "$RUNNER_NETWORK" \
        --label gha.runner.managed=true \
        --label "gha.runner.name=$RUNNER_NAME" \
        "${cpu_args[@]}" \
        "${CONTAINER_ARGS[@]}" \
        --group-add "$docker_sock_group" \
        --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
        -e "GITHUB_REPOSITORY=$REPOSITORY_URL" \
        -e "RUNNER_NAME=$RUNNER_NAME" \
        -e "RUNNER_LABELS=$RUNNER_LABELS" \
        "$IMAGE" start >/dev/null

    sleep 2
    [[ "$(docker inspect -f '{{.State.Running}}' "$cname")" == true ]] \
        || { docker logs --tail 50 "$cname" >&2; err 'Runner container exited immediately.'; }

    write_runner_config
    say "RUNNING: $cname"
    printf '  GitHub repository: %s\n' "$REPOSITORY_URL"
    printf '  Runner name:       %s\n' "$RUNNER_NAME"
    printf '  Custom labels:     %s\n' "$RUNNER_LABELS"
    printf '  CPU pinning:       %s\n' "${CPU_SET:-disabled}"
    printf '  Docker networking: %s\n' "$RUNNER_NETWORK"
    printf '  Persistent state:  %s\n' "$home"
    printf '  Saved settings:    %s\n' "$home/runner.conf"
    printf '  View logs:         ./setup.sh logs %s\n' "$RUNNER_NAME"
    printf '\nVerify runner in the selected repository/organization Actions runner settings: %s\n' "$REPOSITORY_URL"
    printf '%s\n' 'Runner online status does not guarantee dedicated host resources; validate each workload separately.'
}

manage_runner() {
    require_root
    validate_host_directory
    local name="${2:-${RUNNER_NAME:-}}"
    [[ -n "$name" ]] || err "Provide the worker name: ./setup.sh $MODE NAME"
    validate_name "$name"
    local cname="$(container_name "$name")"
    case "$MODE" in
        status)
            docker inspect -f 'Container: {{.Name}} | State: {{.State.Status}} | Restart count: {{.RestartCount}}' "$cname"
            docker ps --filter "name=^/${cname}$" --format 'Image: {{.Image}} | Up: {{.Status}}'
            ;;
        logs)
            docker logs --follow --tail 60 "$cname"
            ;;
        start)
            docker start "$cname"
            ;;
        stop)
            docker stop "$cname"
            ;;
        remove)
            install_docker_if_needed
            [[ -f "${RUNNER_ROOT}/${name}/.runner" ]] || err 'No persistent runner registration found.'
            if existing_container "$name"; then
                docker stop "$cname" >/dev/null || true
                docker rm "$cname" >/dev/null || true
            fi
            local image="${IMAGE}" token=''
            docker image inspect "$image" >/dev/null 2>&1 \
                || err "Runner image $image missing. Build it with setup mode before unregistering."
            say 'Generate a fresh GitHub runner REMOVAL token in the repository Actions runner settings.'
            secret_prompt token 'Paste runner REMOVAL token'
            docker_host_args "$name"
            printf '%s\n' "$token" | docker run --rm -i "${CONTAINER_ARGS[@]}" "$image" unregister
            unset token
            say "Unregistered $name. Runner state remains at ${RUNNER_ROOT}/${name} (not deleted)."
            ;;
    esac
}

doctor() {
    require_linux
    printf 'Host: %s | Architecture: %s\n' "$(hostname -s)" "$(uname -m)"
    if command -v docker >/dev/null 2>&1; then
        docker --version
        docker info --format 'Docker daemon: {{.ServerVersion}}' 2>/dev/null || true
    else
        printf '%s\n' 'Docker Engine not installed.'
    fi
    printf '%s\n' 'CPU topology (informational only; no repo-specific hardware requirements):'
    if command -v lscpu >/dev/null 2>&1; then
        lscpu -e=CPU,CORE,SOCKET,ONLINE || true
    else
        printf '%s\n' 'Install util-linux for detailed CPU topology (lscpu).'
    fi
}
case "$MODE" in
    help|-h|--help) usage ;;
    setup) setup_runner ;;
    doctor) doctor ;;
    status|logs|start|stop|remove) manage_runner "$@" ;;
    *) usage; err "Unsupported command: $MODE" ;;
esac
