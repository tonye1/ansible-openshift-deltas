#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# upload_model_to_minio.sh
#
# Uploads ccf_gru_static_tf2onnx_OS_new.onnx to the MinIO / S3 bucket that
# Red Hat OpenShift AI (RHOAI) uses as a model-storage backend on <KVM_HOST> KVM.
#
# Prerequisites:
#   brew install awscli   OR   pip install awscli
#   The MinIO route must be reachable (VPN / port-forward if needed).
#
# Usage:
#   export MINIO_ENDPOINT=https://minio-api-<KVM_HOST>.<cluster-domain>
#   export MINIO_ACCESS_KEY=<your-access-key>
#   export MINIO_SECRET_KEY=<your-secret-key>
#   export BUCKET=models                   # bucket name in MinIO
#   bash upload_model_to_minio.sh
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_FILE="${SCRIPT_DIR}/../onnx models/ccf_gru_static_tf2onnx_OS_new.onnx"

: "${MINIO_ENDPOINT:?Set MINIO_ENDPOINT to your MinIO API route}"
: "${MINIO_ACCESS_KEY:?Set MINIO_ACCESS_KEY}"
: "${MINIO_SECRET_KEY:?Set MINIO_SECRET_KEY}"
: "${BUCKET:=models}"

MODEL_KEY="ccf_gru_static/1/ccf_gru_static_tf2onnx_OS_new.onnx"

echo "Uploading model to s3://${BUCKET}/${MODEL_KEY} ..."

AWS_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}" \
AWS_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}" \
aws s3 cp \
  "${MODEL_FILE}" \
  "s3://${BUCKET}/${MODEL_KEY}" \
  --endpoint-url "${MINIO_ENDPOINT}" \
  --no-verify-ssl

echo ""
echo "Done. Model available at:"
echo "  endpoint : ${MINIO_ENDPOINT}"
echo "  bucket   : ${BUCKET}"
echo "  key      : ${MODEL_KEY}"
