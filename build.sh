#!/usr/bin/env bash
#
# Build the CSI e2e self-hosted runner image with buildah
#
# The image itself is defined by Containerfile. This driver resolves the kubectl patch releases for every requested minor,
# downloads them, and cosign-verifies each binary against the pinned krel identity on the host. The kubectl wrapper picks the binary
# matching a job's KUBECTL_VERSION at exec time.
#
# Caching has two layers:
#   - kubectl download cache: binaries are kept in ${XDG_CACHE_HOME:-~/.cache}/github-runner alongside their cosign
#     signature and certificate, keyed by minor and patch version (only latest version per minor is retained).
#     Every hit is still cosign-verified, and a failed hit self-heals by re-downloading.
#   - image layers: buildah build --layers reuses unchanged layers from the local store; under GitHub Actions the layer
#     cache is additionally shared with the registry (--cache-from/--cache-to ${CACHE_REF}), so CI only rebuilds layers
#     whose inputs (base image, pinned versions, kubectl binaries) actually moved.
#
# Usage:
#   ./build.sh              bake all kubectl minors (1.31 1.32 1.33 1.34 1.35)
#   ./build.sh 1.33 1.34    bake only these kubectl minors
#
# Overrides via environment:
#   REGISTRY (default ghcr.io)
#   IMAGE (default upcloud-tools/github-runner)
#   BASE_IMAGE (default ${REGISTRY}/actions/actions-runner:latest)
#   APT_MIRROR (default empty) - e.g. http://ee.archive.ubuntu.com/ubuntu
#   GO_VERSION (default 1.26.6) + GO_SHA256
#   HELM_VERSION (default v3.21.0) + HELM_SHA256
#   UPCTL_VERSION (default 3.36.0) + UPCTL_SHA256

set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-upcloud-tools/github-runner}"
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/actions/actions-runner:latest}"
APT_MIRROR="${APT_MIRROR:-}"
GO_VERSION="${GO_VERSION:-1.26.6}"
GO_SHA256="${GO_SHA256:-708effb774be8237570d0add163225abbdfaf4fca28b2611df167beba4feef89}"
HELM_VERSION="${HELM_VERSION:-v3.21.0}"
HELM_SHA256="${HELM_SHA256:-0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36}"
UPCTL_VERSION="${UPCTL_VERSION:-3.36.0}"
UPCTL_SHA256="${UPCTL_SHA256:-49ee0a376d18f5f24ce2653581180696bfc8ae17c9c4262f2c8af3f025e3ce06}"
KUBECTL_MINORS=(1.31 1.32 1.33 1.34 1.35)

CACHE_REF="${REGISTRY}/${IMAGE}-cache"
DL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/github-runner"

# Kubernetes release team signing identity (Fulcio keyless). The kubectl binaries' cosign signature must trace to this
# identity via the sigstore transparency log.
# See: https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/
KUBECTL_SIG_IDENTITY="krel-staging@k8s-releng-prod.iam.gserviceaccount.com"
KUBECTL_SIG_OIDC_ISSUER="https://accounts.google.com"

# Live progress bar on a terminal; a quiet one-line summary (via curl -w) otherwise,
# so CI logs and redirected runs don't fill with bar redraws.
if [ -t 1 ]; then CURL_SHOW=(-fSL --progress-bar); else CURL_SHOW=(-fsSL); fi
# Transient network hiccups shouldn't kill the build; all downloads are idempotent.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-all-errors)
APT_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

SPECIFIED=()
for a in "$@"; do
  case "$a" in
    -*)  echo "unknown flag: $a" >&2; exit 2 ;;
    *)   SPECIFIED+=("$a") ;;
  esac
done
if [ "${#SPECIFIED[@]}" -gt 0 ]; then
  KUBECTL_MINORS=("${SPECIFIED[@]}")
fi

command -v cosign >/dev/null 2>&1 || {
  echo "error: cosign is required to verify kubectl signatures (https://github.com/sigstore/cosign)" >&2
  exit 2
}

# ── Progress reporting ────────────────────────────────────────────────────
# step <label> closes the previous step (recording its duration), prints a timestamped banner, and starts a new timer.
# Whatever step last printed is the one the build was in if it hangs or dies.
CURRENT_STEP=""
STEP_T0=0
STEP_TIMINGS=()
step() {
  if [ -n "$CURRENT_STEP" ]; then
    STEP_TIMINGS+=("${CURRENT_STEP}=$((SECONDS - STEP_T0))s")
  fi
  CURRENT_STEP="$*"
  STEP_T0=$SECONDS
  echo "[$(date +%T)] ==> $CURRENT_STEP"
}
summarize() {
  if [ -n "$CURRENT_STEP" ]; then
    STEP_TIMINGS+=("${CURRENT_STEP}=$((SECONDS - STEP_T0))s")
  fi
  echo "[$(date +%T)] total ${SECONDS}s: ${STEP_TIMINGS[*]}"
}

# Per-run build context (verified kubectl binaries + wrapper) and signature scratch, removed on exit.
# A fresh dir per run guarantees a stale kubectl-<m> from a previous minor list can never ride into the image via the COPY layer.
CTX=$(mktemp -d)
cleanup() {
  summarize
  [ -n "$CTX" ] && rm -rf "$CTX"
}
trap cleanup EXIT

# stage_kubectl <minor> — ensures ${CTX}/kubectl-<minor> exists, preferring the download cache. A hit still runs
# cosign verification against the cached signature and certificate, so a corrupted or poisoned cache entry can never
# reach the image; a failed hit self-heals by re-downloading. Misses are downloaded, cosign-verified, and cached
# (keeping only the latest version per minor).
stage_kubectl() {
  local m="$1"
  local kver base cached ok=0
  kver=$(curl "${CURL_RETRY[@]}" -fsSL "https://dl.k8s.io/release/stable-${m}.txt")
  base="https://dl.k8s.io/release/${kver}/bin/linux/amd64"
  cached="${DL_CACHE}/kubectl-${m}-${kver}"

  if [ -f "$cached" ] && [ -f "${cached}.sig" ] && [ -f "${cached}.cert" ]; then
    echo "[$(date +%T)] verifying cached kubectl ${kver} (minor ${m}) against '${KUBECTL_SIG_IDENTITY}'"
    if cosign verify-blob "$cached" \
      --signature "${cached}.sig" \
      --certificate "${cached}.cert" \
      --certificate-identity "$KUBECTL_SIG_IDENTITY" \
      --certificate-oidc-issuer "$KUBECTL_SIG_OIDC_ISSUER"; then
      echo "  kubectl ${m} ${kver}: download-cache hit (verified)"
      ok=1
    else
      echo "  kubectl ${m} ${kver}: cached entry failed verification, re-downloading" >&2
    fi
  fi

  if [ "$ok" = 0 ]; then
    curl "${CURL_SHOW[@]}" "${CURL_RETRY[@]}" "${base}/kubectl" -o "${CTX}/kubectl-${m}" \
      -w "kubectl ${kver}: %{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n"
    curl "${CURL_RETRY[@]}" -fsSL "${base}/kubectl.sig"  -o "${CTX}/${m}.sig"
    curl "${CURL_RETRY[@]}" -fsSL "${base}/kubectl.cert" -o "${CTX}/${m}.cert.b64"
    base64 -d "${CTX}/${m}.cert.b64" > "${CTX}/${m}.cert"

    echo "[$(date +%T)] verifying kubectl ${kver} (minor ${m}) against '${KUBECTL_SIG_IDENTITY}'"
    cosign verify-blob "${CTX}/kubectl-${m}" \
      --signature "${CTX}/${m}.sig" \
      --certificate "${CTX}/${m}.cert" \
      --certificate-identity "$KUBECTL_SIG_IDENTITY" \
      --certificate-oidc-issuer "$KUBECTL_SIG_OIDC_ISSUER"

    mkdir -p "$DL_CACHE"
    mv "${CTX}/kubectl-${m}" "$cached"
    cp "${CTX}/${m}.sig" "${cached}.sig"
    cp "${CTX}/${m}.cert" "${cached}.cert"
    # Keep one version per minor; drop superseded downloads and their signature material.
    find "$DL_CACHE" -maxdepth 1 -name "kubectl-${m}-*" \
      ! -name "kubectl-${m}-${kver}" ! -name "kubectl-${m}-${kver}.sig" ! -name "kubectl-${m}-${kver}.cert" -delete
    rm -f "${CTX}/${m}.sig" "${CTX}/${m}.cert" "${CTX}/${m}.cert.b64"
  fi
  cp "$cached" "${CTX}/kubectl-${m}"
}

TAG="${REGISTRY}/${IMAGE}:latest"
echo "==> Building ${TAG} (kubectl ${KUBECTL_MINORS[*]}, go ${GO_VERSION}, upctl ${UPCTL_VERSION}, helm ${HELM_VERSION})"

step "prepare build context"
# Drop cache entries of minors no longer being baked, so the persisted cache can't accumulate dead versions.
for f in "$DL_CACHE"/kubectl-*; do
  [ -e "$f" ] || continue
  fm="$(basename "$f")"; fm="${fm#kubectl-}"; fm="${fm%%-*}"
  for m in "${KUBECTL_MINORS[@]}"; do
    [ "$fm" = "$m" ] && continue 2
  done
  rm -f "$f"
done

for m in "${KUBECTL_MINORS[@]}"; do
  stage_kubectl "$m"
done

# ── kubectl wrapper: dispatch on KUBECTL_VERSION at exec time ─────────────
# Static file from the repo; its content participates in the COPY layer's cache key.
cp kubectl-wrapper "${CTX}/kubectl-wrapper"

step "build ${TAG}"
BUILD_FLAGS=(-f Containerfile --layers
  --build-arg "BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "APT_MIRROR=${APT_MIRROR}"
  --build-arg "APT_OPTS=${APT_OPTS[*]}"
  --build-arg "CURL_RETRY=${CURL_RETRY[*]}"
  --build-arg "GO_VERSION=${GO_VERSION}"
  --build-arg "GO_SHA256=${GO_SHA256}"
  --build-arg "UPCTL_VERSION=${UPCTL_VERSION}"
  --build-arg "UPCTL_SHA256=${UPCTL_SHA256}"
  --build-arg "HELM_VERSION=${HELM_VERSION}"
  --build-arg "HELM_SHA256=${HELM_SHA256}")

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "  sharing layer cache via ${CACHE_REF}"
  BUILD_FLAGS+=(--cache-from "$CACHE_REF" --cache-to "$CACHE_REF")
fi

buildah build "${BUILD_FLAGS[@]}" -t "$TAG" "$CTX"

echo "[$(date +%T)] ==> Done. Built ${TAG}"
