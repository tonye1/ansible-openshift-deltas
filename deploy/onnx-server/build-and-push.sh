#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-and-push.sh
#
# Builds the onnx-server image inside OpenShift using a BuildConfig
# (Docker strategy, Binary source). No podman/docker/buildah needed on the
# bastion — the build runs as a Pod on the s390x compute nodes and the image
# is pushed directly into the internal registry.
#
# Run on bastion <bastion-host> after 'oc login'.
#
# Usage:
#   bash build-and-push.sh
# ---------------------------------------------------------------------------
set -euo pipefail

NAMESPACE="fraud-detection"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Step 1: Ensure namespace exists ==="
oc get namespace "${NAMESPACE}" 2>/dev/null || oc new-project "${NAMESPACE}"

echo ""
echo "=== Step 2: Create ImageStream and BuildConfig ==="
oc apply -f "${SCRIPT_DIR}/buildconfig.yaml"

echo ""
echo "=== Step 3: Start the build (uploads source dir, builds on cluster) ==="
# --from-dir uploads the onnx-server/ directory to the build pod as the
# binary source. The build pod runs on s390x and produces an s390x image.
oc start-build onnx-server \
  -n "${NAMESPACE}" \
  --from-dir="${SCRIPT_DIR}" \
  --follow \
  --wait

echo ""
echo "=== Done ==="
echo "  Image in internal registry:"
echo "  image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/onnx-server:latest"
echo ""
echo "Next steps:"
echo "  oc apply -f ${SCRIPT_DIR}/serving-runtime.yaml"
echo "  oc apply -f ai-on-z-fraud-detection/deploy/inferenceservice.yaml"
