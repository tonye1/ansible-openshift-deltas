#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# repush-minio-image.sh
#
# Recovers MinIO after the OCP internal registry loses the image.
# Symptom: minio pod stuck in ImagePullBackOff after cluster restart or
#          registry PVC wipe — all Triton predictor pods then crash-loop
#          in Init:CrashLoopBackOff because storage-initializer can't reach
#          minio.minio.svc.cluster.local:9000.
#
# Run this ON <KVM_HOST> (<REPLACE>) — podman and the cached image live there.
#
# Prerequisites:
#   - podman image present locally (verify: podman images | grep minio)
#   - SSH access to <BASTION_HOSTNAME> (<bastion-host>) to obtain an oc token
#
# Usage:
#   bash repush-minio-image.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REGISTRY="default-route-openshift-image-registry.apps.<CLUSTER_DOMAIN>"
IMAGE="${REGISTRY}/minio/minio:RELEASE.2024-01-16T16-07-38Z"
BASTION_HOSTNAME="<USERat><bastion-host>"

# Verify the image is present locally
if ! podman image exists "${IMAGE}"; then
  echo "[error] Image not found locally: ${IMAGE}"
  echo "        Pull it first: podman pull docker.io/minio/minio:RELEASE.2024-01-16T16-07-38Z"
  echo "        Then tag it:   podman tag docker.io/minio/minio:RELEASE.2024-01-16T16-07-38Z ${IMAGE}"
  exit 1
fi

# Get an OCP token from <BASTION_HOSTNAME>
# SSH <password> prompt will appear — enter it when asked
echo "[info] Getting OCP token from ${BASTION_HOSTNAME} (enter SSH <password> when prompted)..."
TOKEN=$(ssh "${BASTION_HOSTNAME}" 'oc whoami -t')

if [[ -z "${TOKEN}" ]]; then
  echo "[error] Failed to obtain token. Is oc logged in on <BASTION_HOSTNAME>?"
  echo "        Run on <BASTION_HOSTNAME>: bash login.sh"
  exit 1
fi

echo "[info] Token obtained."

# Log in to the internal registry
# Username must be 'unused' — OCP validates only the token, not the username
echo "[info] Logging in to ${REGISTRY}..."
podman login --tls-verify=false \
  -u unused \
  -p "${TOKEN}" \
  "${REGISTRY}"

# Push the image
echo "[info] Pushing ${IMAGE}..."
podman push --tls-verify=false "${IMAGE}"

echo ""
echo "[done] Image pushed successfully."
echo "       Now on <BASTION_HOSTNAME> run:"
echo ""
echo "  oc set image deployment/minio \\"
echo "    minio=image-registry.openshift-image-registry.svc:5000/minio/minio:RELEASE.2024-01-16T16-07-38Z \\"
echo "    -n minio"
echo ""
echo "  oc rollout restart deployment/ccf-gru-static-triton-predictor -n fraud-detection"
