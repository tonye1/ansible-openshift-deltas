#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# upload_model_via_oc.sh
#
# Uploads ccf_gru_static_tf2onnx_OS_new.onnx to the in-cluster MinIO
# instance using only 'oc' (OpenShift CLI) — no aws CLI or mc client needed.
#
# Strategy:
#   1. Stream the .onnx file into the pod using 'oc exec -i cat >' — avoids
#      'oc cp' which requires tar inside the container.
#   2. Call mc via 'env -i' to wipe all inherited environment variables
#      (Kubernetes injects MINIO_PORT_* vars that mc misparses as JSON aliases)
#      then pass only HOME and PATH so mc can find its binary and write its
#      config, and supply credentials via explicit 'mc alias set'.
#
# Prerequisites on the bastion (<bastion-host>):
#   - oc CLI installed and logged in    (oc login ...)
#   - The .onnx file present in the current directory
#
# Usage (run on bastion <bastion-host>):
#   bash upload_model_via_oc.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ONNX_FILE="ccf_gru_static_tf2onnx_OS_new.onnx"
BUCKET="models"
MODEL_KEY="ccf_gru_static/1/${ONNX_FILE}"

MINIO_NS="minio"
MINIO_USER="<MINIO_USER>"
MINIO_PASS="<MINIO_PASSWORD>"

# ── Step 1: locate the running MinIO pod ────────────────────────────────────
echo "Finding MinIO pod in namespace '${MINIO_NS}'..."
MINIO_POD=$(oc get pod -n "${MINIO_NS}" -l app=minio \
  -o jsonpath='{.items[0].metadata.name}')
echo "  Pod: ${MINIO_POD}"

# ── Step 2: stream the file into the pod via oc exec + shell stdin ──────────
# oc cp requires tar inside the container — MinIO image does not have it.
echo "Streaming ${ONNX_FILE} into pod /tmp/ (no tar required)..."
oc exec -n "${MINIO_NS}" "${MINIO_POD}" -i -- sh -c "cat > /tmp/${ONNX_FILE}" \
  < "${ONNX_FILE}"
echo "  Transfer complete."

# ── Step 3: create bucket + upload via mc with a clean environment ───────────
# Problem: Kubernetes injects MINIO_PORT, MINIO_PORT_9000_TCP etc. into the
# pod. mc treats any MINIO_* var as a JSON-encoded alias config and fails to
# parse tcp://... values. curl is not present in this image either.
# Solution: run mc under 'env -i' which clears ALL inherited env vars, then
# supply only HOME (so mc can write /tmp/.mc config) and PATH.
echo "Creating bucket '${BUCKET}' and uploading model..."
oc exec -n "${MINIO_NS}" "${MINIO_POD}" -- \
  env -i HOME=/tmp PATH=/usr/local/bin:/usr/bin:/bin \
  mc alias set local http://localhost:9000 "${MINIO_USER}" "${MINIO_PASS}" --api S3v4

oc exec -n "${MINIO_NS}" "${MINIO_POD}" -- \
  env -i HOME=/tmp PATH=/usr/local/bin:/usr/bin:/bin \
  mc mb --ignore-existing local/"${BUCKET}"

echo "Uploading ${ONNX_FILE}..."
oc exec -n "${MINIO_NS}" "${MINIO_POD}" -- \
  env -i HOME=/tmp PATH=/usr/local/bin:/usr/bin:/bin \
  mc cp /tmp/"${ONNX_FILE}" local/"${BUCKET}"/"${MODEL_KEY}"

echo "Verifying..."
oc exec -n "${MINIO_NS}" "${MINIO_POD}" -- \
  env -i HOME=/tmp PATH=/usr/local/bin:/usr/bin:/bin \
  mc ls local/"${BUCKET}"/ccf_gru_static/1/

echo ""
echo "Upload complete."
echo "  MinIO API (in-cluster) : http://minio.minio.svc.cluster.local:9000"
echo "  Bucket                 : ${BUCKET}"
echo "  Key                    : ${MODEL_KEY}"
echo ""
echo "Next: apply ai-on-z-fraud-detection/deploy/inferenceservice.yaml"
