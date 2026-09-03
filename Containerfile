# Runner image layers. Build via ./build.sh — it is the single source of truth for tool versions and checksums
# and passes them in as build args. Keep the layer order rare -> frequent change so cache reuse is maximized.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Base image config sets USER runner; the install steps below need root.
# Restored to runner before the final layer.
USER root

ARG CURL_RETRY
ARG APT_OPTS
ARG APT_MIRROR
RUN if [ -n "${APT_MIRROR}" ]; then \
      sed -i -E "s|^URIs: https?://(archive|security)\.ubuntu\.com/ubuntu$|URIs: ${APT_MIRROR}|" /etc/apt/sources.list.d/ubuntu.sources; \
    fi

# ── distro packages ───────────────────────────────────────────────────────
RUN apt-get ${APT_OPTS} update \
 && apt-get ${APT_OPTS} install -y --no-install-recommends make gettext-base ca-certificates curl gnupg

# ── go ────────────────────────────────────────────────────────────────────
ARG GO_VERSION
ARG GO_SHA256
RUN curl -fsSL ${CURL_RETRY} -w "go: %{size_download}B at %{speed_download}B/s\n" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz \
 && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c \
 && tar -C /usr/local -xzf /tmp/go.tar.gz \
 && rm /tmp/go.tar.gz
ENV PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ── upcloud-cli ───────────────────────────────────────────────────────────
ARG UPCTL_VERSION
ARG UPCTL_SHA256
RUN curl -fsSL ${CURL_RETRY} -o /tmp/upcloud-cli.deb -w "upcloud-cli: %{size_download}B at %{speed_download}B/s\n" \
      "https://github.com/UpCloudLtd/upcloud-cli/releases/download/v${UPCTL_VERSION}/upcloud-cli_${UPCTL_VERSION}_amd64.deb" \
 && echo "${UPCTL_SHA256}  /tmp/upcloud-cli.deb" | sha256sum -c \
 && apt-get ${APT_OPTS} install -y --no-install-recommends /tmp/upcloud-cli.deb \
 && rm -rf /tmp/upcloud-cli.deb /var/lib/apt/lists/*

# ── helm ──────────────────────────────────────────────────────────────────
ARG HELM_VERSION
ARG HELM_SHA256
RUN curl -fsSL ${CURL_RETRY} -w "helm: %{size_download}B at %{speed_download}B/s\n" \
      "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
 && echo "${HELM_SHA256}  /tmp/helm.tar.gz" | sha256sum -c \
 && tar -xzf /tmp/helm.tar.gz -C /tmp \
 && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
 && rm -rf /tmp/linux-amd64 /tmp/helm.tar.gz

# ── kubectl minors (host-verified by build.sh) + version-dispatch wrapper ─
COPY kubectl-1.* /usr/local/bin/
COPY kubectl-wrapper /usr/local/bin/kubectl
RUN chmod 0755 /usr/local/bin/kubectl-1.* /usr/local/bin/kubectl \
 && ln -sf "$(ls /usr/local/bin/kubectl-1.* | sort -V | tail -n1)" /usr/local/bin/kubectl-latest

USER runner
