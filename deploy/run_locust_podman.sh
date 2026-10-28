#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_locust_podman.sh
#
# Runs the Locust load test from <KVM_HOST> using podman.
#
# locustio/locust does NOT publish a linux/s390x image on Docker Hub.
# This script builds a local s390x image from locust/Dockerfile on first run
# (uses python:3.11-slim which does publish s390x, installs g++ inside the
# build layer to compile pyzmq, then removes it from the final image).
#
# Prerequisites (on <KVM_HOST>):
#   - podman 5.8.2+ (confirmed available)
#   - Internet access to docker.io/library/python:3.11-slim
#   - locustfile.py and locust/Dockerfile in the same directory as this script
#   - LOCUST_TOKEN exported (oc is not in PATH on <KVM_HOST>)
#
# Usage:
#   # Copy files to <KVM_HOST> (run from bastion or laptop):
#   scp deploy/locustfile.py \
#       deploy/run_locust_podman.sh \
#       deploy/locust/Dockerfile \
#       <USERat><KVM_HOST>:~/locust/
#
#   # Then on <KVM_HOST>:
#   export LOCUST_TOKEN=<token from: oc whoami -t on <BASTION_HOSTNAME>>
#   export LOCUST_VERIFY=false
#   cd ~/locust
#   bash run_locust_podman.sh
#
# Optional overrides (export before running):
#   LOCUST_USERS      — number of concurrent users  (default: 10)
#   LOCUST_RATE       — spawn rate users/sec         (default: 2)
#   LOCUST_RUNTIME    — test duration                (default: 60s)
#   LOCUST_HOST       — inference route URL          (default: see below)
#   LOCUST_TOKEN      — bearer token                 (required)
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INFER_HOST="${LOCUST_HOST:-https://ccf-gru-static-predictor-fraud-detection.apps.<CLUSTER_DOMAIN>}"
USERS="${LOCUST_USERS:-10}"
RATE="${LOCUST_RATE:-2}"
RUNTIME="${LOCUST_RUNTIME:-60s}"

# LOCUST_TOKEN must be set — oc is not installed on <KVM_HOST>
if [[ -z "${LOCUST_TOKEN:-}" ]]; then
  if command -v oc &>/dev/null; then
    LOCUST_TOKEN=$(oc whoami -t)
    echo "[info] Obtained token via 'oc whoami -t'"
  else
    echo "[error] LOCUST_TOKEN is not set and 'oc' is not in PATH."
    echo "        On <BASTION_HOSTNAME> run:  oc whoami -t"
    echo "        Then on <KVM_HOST>: export LOCUST_TOKEN=<that token>"
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCUST_FILE="${SCRIPT_DIR}/locustfile.py"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"

if [[ ! -f "${LOCUST_FILE}" ]]; then
  echo "[error] locustfile.py not found at: ${LOCUST_FILE}"
  exit 1
fi

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "[error] Dockerfile not found at: ${DOCKERFILE}"
  echo "        Copy deploy/locust/Dockerfile to the same directory as this script."
  exit 1
fi

# Output directory for reports (created next to this script)
REPORT_DIR="${SCRIPT_DIR}/locust-reports"
mkdir -p "${REPORT_DIR}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# Build the s390x locust image locally (locustio/locust has no s390x image)
# The build is skipped if the image already exists locally.
# ---------------------------------------------------------------------------
IMAGE="locust-s390x:latest"

if podman image exists "${IMAGE}"; then
  echo "[info] Image ${IMAGE} already exists — skipping build."
  echo "       To force a rebuild: podman rmi ${IMAGE}"
else
  echo "[info] Building ${IMAGE} from ${DOCKERFILE} ..."
  echo "       (this takes ~3-5 minutes on first run — installs g++ + locust inside the build)"
  podman build -t "${IMAGE}" -f "${DOCKERFILE}" "${SCRIPT_DIR}"
  echo "[info] Build complete."
fi

# ---------------------------------------------------------------------------
# Run Locust headless
# ---------------------------------------------------------------------------
echo ""
echo "[info] Starting Locust load test"
echo "  Host        : ${INFER_HOST}"
echo "  Users       : ${USERS}"
echo "  Spawn rate  : ${RATE}/s"
echo "  Duration    : ${RUNTIME}"
echo "  HTML report : locust-reports/locust-report-${TIMESTAMP}.html"
echo "  CSV prefix  : locust-reports/locust-${TIMESTAMP}"
echo ""

podman run --rm \
  --network=host \
  -v "${SCRIPT_DIR}:/mnt/locust:z" \
  -e LOCUST_TOKEN="${LOCUST_TOKEN}" \
  -e LOCUST_VERIFY="${LOCUST_VERIFY:-false}" \
  "${IMAGE}" \
    -f /mnt/locust/locustfile.py \
    --headless \
    --users "${USERS}" \
    --spawn-rate "${RATE}" \
    --run-time "${RUNTIME}" \
    --host "${INFER_HOST}" \
    --html /mnt/locust/locust-reports/locust-report-"${TIMESTAMP}".html \
    --csv  /mnt/locust/locust-reports/locust-"${TIMESTAMP}"

echo ""
echo "[done] Reports written to ${REPORT_DIR}/"
echo "       HTML : locust-report-${TIMESTAMP}.html"
echo "       CSV  : locust-${TIMESTAMP}_stats.csv"
echo "              locust-${TIMESTAMP}_stats_history.csv"
echo "              locust-${TIMESTAMP}_failures.csv"
