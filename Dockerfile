FROM ubuntu:24.04

ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
ARG RUNNER_ARCH=x64
ARG RUNNER_UID=1001
ARG RUNNER_GID=1001

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_DISTRIBUTION=/opt/gha-runner-distribution

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl docker.io git gzip jq \
        libicu74 libkrb5-3 liblttng-ust1 libssl3t64 \
        software-properties-common sudo tar tini unzip zlib1g \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${RUNNER_GID}" runner \
    && useradd --uid "${RUNNER_UID}" --gid "${RUNNER_GID}" \
        --create-home --shell /bin/bash runner \
    && printf '%s\n' 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

RUN mkdir -p "${RUNNER_DISTRIBUTION}" \
    && curl --fail --silent --show-error --location --retry 3 \
       "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
       -o /tmp/gha-runner.tar.gz \
    && echo "${RUNNER_SHA256}  /tmp/gha-runner.tar.gz" | sha256sum --check --status \
    && tar -xzf /tmp/gha-runner.tar.gz -C "${RUNNER_DISTRIBUTION}" \
    && rm /tmp/gha-runner.tar.gz \
    && chown -R runner:runner "${RUNNER_DISTRIBUTION}"

COPY --chown=runner:runner entrypoint.sh /usr/local/bin/gha-entrypoint
RUN chmod 0755 /usr/local/bin/gha-entrypoint

USER runner
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/gha-entrypoint"]
CMD ["start"]
