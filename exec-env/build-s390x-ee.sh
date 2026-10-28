#!/usr/bin/env bash
# build-s390x-ee.sh
# Build an s390x Ansible Execution Environment on an x86_64 RHEL 9 host.
#
# Prerequisites (run once):
#   sudo dnf install -y podman qemu-user-static ansible-builder
#   podman run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes
#
# Usage:
#   cd exec-env/
#   bash build-s390x-ee.sh [image-tag]
#
# The resulting image is saved as s390x-ee.tar in the current directory.

set -euo pipefail

IMAGE_TAG="${1:-ocp-provisioning-ee:s390x}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Working directory: ${SCRIPT_DIR}"
cd "${SCRIPT_DIR}"

# ── 1. Verify prerequisites ──────────────────────────────────────────────────

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. Install it first:"
    echo "  sudo dnf install -y $2"
    exit 1
  fi
}

check_cmd podman   podman
check_cmd ansible-builder ansible-builder

# ── 2. Enable s390x binfmt emulation ────────────────────────────────────────

echo "==> Checking s390x binfmt emulation..."
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-s390x ]]; then
  echo "    Registering QEMU s390x binfmt handler..."
  podman run --rm --privileged \
    docker.io/multiarch/qemu-user-static --reset -p yes
else
  echo "    qemu-s390x binfmt already registered."
fi

# ── 3. Log in to Red Hat registry ───────────────────────────────────────────

echo "==> Logging in to registry.redhat.io..."
echo "    (Requires a Red Hat registry service account or your RH credentials)"
podman login registry.redhat.io

# ── 4. Pull the s390x base image explicitly ──────────────────────────────────
# ansible-builder does not pass --platform to the initial pull, so we pre-pull
# the s390x variant before the build.

BASE_IMAGE="registry.redhat.io/ansible-automation-platform-25/ee-minimal-rhel9:latest"
echo "==> Pre-pulling s390x base image..."
podman pull --platform linux/s390x "${BASE_IMAGE}"

# ── 5. Build the EE ──────────────────────────────────────────────────────────

echo "==> Building EE for linux/s390x  →  ${IMAGE_TAG}"
ansible-builder build \
  --file execution-environment.yml \
  --tag "${IMAGE_TAG}" \
  --container-runtime podman \
  --build-arg "ANSIBLE_GALAXY_SERVER_TIMEOUT=120" \
  --verbosity 2

# ansible-builder does not natively expose --platform, so after the build
# verify the image architecture:
ARCH=$(podman inspect "${IMAGE_TAG}" \
  --format '{{.Architecture}}' 2>/dev/null || echo "unknown")

if [[ "${ARCH}" != "s390x" ]]; then
  echo ""
  echo "WARNING: Built image architecture is '${ARCH}', not 's390x'."
  echo "  This means the base image pulled was x86_64."
  echo "  Re-run with the workaround below, then rebuild."
  echo ""
  echo "  Workaround — build via podman buildx directly:"
  echo "    ansible-builder create --file execution-environment.yml --output-filename Containerfile"
  echo "    podman buildx build --platform linux/s390x \\"
  echo "      -f context/Containerfile \\"
  echo "      -t ${IMAGE_TAG} \\"
  echo "      context/"
  exit 1
fi

echo "==> Architecture confirmed: ${ARCH}"

# ── 6. Export to tar ─────────────────────────────────────────────────────────

echo "==> Exporting image to s390x-ee.tar..."
podman save "${IMAGE_TAG}" -o s390x-ee.tar
echo "==> Done.  Image saved to: ${SCRIPT_DIR}/s390x-ee.tar"
echo ""
echo "To load on the s390x host or AAP:"
echo "  podman load -i s390x-ee.tar"
echo "  # or push directly:"
echo "  podman push ${IMAGE_TAG} <your-registry>/<repo>/${IMAGE_TAG}"
