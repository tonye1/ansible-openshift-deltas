#!/usr/bin/env bash
# run-master.sh — start the Locust master on the bastio
#
# Target: ccf_gru_static ONNX model on Red Hat OpenShift AI / <KVM_HOST>
# Runtime: IBM Z Accelerated NVIDIA Triton Inference Server
# Cluster domain: <CLUSTER_DOMAIN>
#
# Prerequisites on the bastion:
#   podman installed    (already present on bastion <BASTION_HOSTNAME>)
#   oc logged in        (for LOCUST_TOKEN)
#
# Usage:
#   chmod +x run-master.sh
#   ./run-master.sh
#
# Web UI available at http://<bastion-host>:8089
# Workers inside OpenShift will connect to <bastion-host>:5557

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCUST_FILE="${SCRIPT_DIR}/locustfile.py"

# Triton InferenceService Route (created by triton-inferenceservice.yaml)
# Previous custom onnx-server route: ccf-gru-static-predictor-fraud-detection.apps.ocpz...
TARGET_HOST="${TARGET_HOST:-https://ccf-gru-static-triton-fraud-detection.apps.<CLUSTER_DOMAIN>}"

# Bearer token — workers run inside OpenShift so they can reach the internal
# service directly; the master only needs the token for the smoke test.
LOCUST_TOKEN="${LOCUST_TOKEN:-$(oc whoami -t 2>/dev/null || echo '')}"

echo "Starting Locust master on bastion"
echo "  Web UI  : http://<bastion-host>:8089"
echo "  Workers : connect to <bastion-host>:5557"
echo "  Target  : ${TARGET_HOST}"
echo ""

podman run --rm \
  --name locust-master \
  -p 8089:8089 \
  -p 5557:5557 \
  -e LOCUST_TOKEN="${LOCUST_TOKEN}" \
  -v "${LOCUST_FILE}:/locust/locustfile.py:ro,Z" \
  locustio/locust:latest \
  -f /locust/locustfile.py \
  --master \
  --master-bind-host=0.0.0.0 \
  --master-bind-port=5557 \
  --web-port=8089 \
  --host="${TARGET_HOST}"
