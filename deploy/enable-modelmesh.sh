#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# enable-modelmesh.sh
#
# Enables ModelMesh Serving in the RHOAI DataScienceCluster.
# ModelMesh ships Red Hat-built OVMS (OpenVINO Model Server) images that
# are multi-arch including s390x — unlike Triton (x86/GPU only).
#
# Run on bastion <bastion-host> after 'oc login'.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "=== Backing up current DataScienceCluster spec ==="
oc get datasciencecluster default-dsc -o yaml > /tmp/dsc-backup-$(date +%Y%m%d-%H%M%S).yaml
echo "  Backup saved to /tmp/dsc-backup-*.yaml"

echo ""
echo "=== Enabling modelmeshserving ==="
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "modelmeshserving": {
        "managementState": "Managed"
      }
    }
  }
}'

echo ""
echo "=== Waiting for ModelMesh pods to start (up to 5 minutes) ==="
echo "Watching redhat-ods-applications namespace..."
timeout 300 bash -c '
  until oc get pods -n redhat-ods-applications | grep -q "modelmesh\|odh-model-mesh"; do
    echo "  waiting for modelmesh pods..."
    sleep 10
  done
' && echo "ModelMesh pods appeared." || echo "Timed out — check manually."

echo ""
echo "=== Current pods in redhat-ods-applications ==="
oc get pods -n redhat-ods-applications

echo ""
echo "=== ServingRuntimes now available ==="
oc get servingruntime -A

echo ""
echo "Next: check that 'ovms-runtime' or 'openvino-*' appears in the ServingRuntime list above."
echo "Then run: oc apply -f ai-on-z-fraud-detection/deploy/inferenceservice.yaml"
