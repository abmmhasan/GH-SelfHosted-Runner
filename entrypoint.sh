#!/usr/bin/env bash
set -Eeuo pipefail

: "${RUNNER_HOME:?An absolute RUNNER_HOME is required}"
: "${RUNNER_DISTRIBUTION:?RUNNER_DISTRIBUTION is required}"

case "$RUNNER_HOME" in
    /*) ;;
    *) printf '%s\n' 'RUNNER_HOME must be an absolute path' >&2; exit 1 ;;
esac

mkdir -p "$RUNNER_HOME"

# Runner configuration and Docker job workspace are preserved in the same
# absolute host/container location. That keeps service-container binds valid.
# Restore runner binaries from the pinned image; never copy a token into it.
cp -a "${RUNNER_DISTRIBUTION}/." "${RUNNER_HOME}/"
cd "$RUNNER_HOME"

case "${1:-start}" in
    register)
        : "${GITHUB_REPOSITORY:?GitHub repository or organization URL is required}"
        : "${RUNNER_NAME:?Runner name is required}"
        : "${RUNNER_LABELS:?Runner labels are required}"
        if [[ -e .runner ]]; then
            printf '%s\n' 'Runner configuration already exists; refusing to overwrite it.' >&2
            exit 1
        fi
        IFS= read -r registration_token || true
        if [[ -z "$registration_token" ]]; then
            printf '%s\n' 'Missing registration token on standard input.' >&2
            exit 1
        fi
        ./config.sh \
            --unattended \
            --url "$GITHUB_REPOSITORY" \
            --token "$registration_token" \
            --name "$RUNNER_NAME" \
            --labels "$RUNNER_LABELS" \
            --work "${RUNNER_HOME}/_work"
        unset registration_token
        ;;
    start)
        if [[ ! -f .runner ]]; then
            printf '%s\n' 'Runner not configured. Execute setup.sh setup first.' >&2
            exit 1
        fi
        exec ./run.sh
        ;;
    unregister)
        if [[ ! -f .runner ]]; then
            printf '%s\n' 'Runner is already unregistered.' >&2
            exit 0
        fi
        IFS= read -r removal_token || true
        if [[ -z "$removal_token" ]]; then
            printf '%s\n' 'Missing a fresh GitHub removal token.' >&2
            exit 1
        fi
        ./config.sh remove --token "$removal_token"
        unset removal_token
        ;;
    *)
        printf 'Unknown runner action: %s\n' "$1" >&2
        exit 2
        ;;
esac
