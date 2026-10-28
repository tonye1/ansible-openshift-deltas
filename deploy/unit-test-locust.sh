#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# unit-test-locust.sh
#
# Single-request smoke test for the ccf_gru_static ONNX inference endpoint.
# Verifies connectivity, auth, DNS, and model response before running Locust.
#
# Run on <KVM_HOST> (or <BASTION_HOSTNAME>):
#   bash unit-test-locust.sh
#
# Prerequisites:
#   - LOCUST_TOKEN exported  (or oc in PATH)
#   - /etc/hosts entry for the *.apps.ocpz domain (on <KVM_HOST>)
# ---------------------------------------------------------------------------
set -euo pipefail

INFER_HOST="${LOCUST_HOST:-https://ccf-gru-static-predictor-fraud-detection.apps.<CLUSTER_DOMAIN>}"
INFER_URL="${INFER_HOST}/v2/models/ccf_gru_static/versions/1/infer"
HEALTH_URL="${INFER_HOST}/v2/health/ready"

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
if [[ -z "${LOCUST_TOKEN:-}" ]]; then
  if command -v oc &>/dev/null; then
    TOKEN=$(oc whoami -t)
    echo "[info] Token obtained via 'oc whoami -t'"
  elif command -v ssh &>/dev/null; then
    echo "[info] Fetching token from bastion  ..."
    TOKEN=$(ssh <bastion-user@bastion-host> 'oc whoami -t')
  else
    echo "[error] LOCUST_TOKEN is not set and neither 'oc' nor SSH bastion is available."
    exit 1
  fi
else
  TOKEN="${LOCUST_TOKEN}"
fi

# ---------------------------------------------------------------------------
# DNS check
# ---------------------------------------------------------------------------
HOSTNAME=$(echo "${INFER_HOST}" | sed 's|https\?://||' | cut -d/ -f1)
echo ""
echo "=== Step 1: DNS resolution ==="
if host "${HOSTNAME}" &>/dev/null; then
  RESOLVED_IP=$(host "${HOSTNAME}" | awk '/has address/{print $4; exit}')
  echo "[ok] ${HOSTNAME} -> ${RESOLVED_IP}"
else
  echo "[FAIL] Cannot resolve ${HOSTNAME}"
  echo "       Add to /etc/hosts on this host:"
  echo "       <ingress-ip>  ${HOSTNAME}"
  echo "       Get ingress IP from bastion: ssh <bastion-user@bastion-host> 'oc get nodes -o wide | awk \"NR>1{print \$6}\" | head -1'"
  exit 1
fi

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Health endpoint ==="
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${HEALTH_URL}")
if [[ "${HTTP_CODE}" == "200" ]]; then
  echo "[ok] GET ${HEALTH_URL} -> HTTP ${HTTP_CODE}"
elif [[ "${HTTP_CODE}" == "401" || "${HTTP_CODE}" == "403" ]]; then
  echo "[FAIL] HTTP ${HTTP_CODE} — token is invalid or expired."
  echo "       Refresh with: export LOCUST_TOKEN=\$(ssh <bastion-user@bastion-host> 'oc whoami -t')"
  exit 1
else
  echo "[FAIL] HTTP ${HTTP_CODE} — unexpected response from health endpoint."
  exit 1
fi

# ---------------------------------------------------------------------------
# Inference request
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Inference request (shape [7,16,220], all zeros) ==="

PAYLOAD=$(python3 -c "
import json
data = [0.0] * (7 * 16 * 220)
print(json.dumps({
  'inputs': [{
    'name':     'input',
    'shape':    [7, 16, 220],
    'datatype': 'FP32',
    'data':     data
  }]
}))")

RESPONSE=$(curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${INFER_URL}")

if [[ -z "${RESPONSE}" ]]; then
  echo "[FAIL] Empty response — server returned nothing."
  echo "       Check /etc/hosts and token validity."
  exit 1
fi

# Parse and validate
python3 - << PYEOF
import json, sys

try:
    body = json.loads('''${RESPONSE}''')
except json.JSONDecodeError as e:
    print(f"[FAIL] Response is not valid JSON: {e}")
    print(f"       Raw response: ${RESPONSE}"[:400])
    sys.exit(1)

if "error" in body:
    print(f"[FAIL] Server returned error: {body['error']}")
    sys.exit(1)

try:
    outputs = body["outputs"][0]["data"]
except (KeyError, IndexError) as e:
    print(f"[FAIL] Unexpected response shape: {e}")
    print(json.dumps(body, indent=2)[:400])
    sys.exit(1)

expected = 7 * 16   # 112 floats
if len(outputs) != expected:
    print(f"[FAIL] Output length {len(outputs)} != expected {expected}")
    sys.exit(1)

print(f"[ok]  model_name    : {body.get('model_name')}")
print(f"[ok]  model_version : {body.get('model_version')}")
print(f"[ok]  output shape  : {body['outputs'][0]['shape']}")
print(f"[ok]  output values : {len(outputs)} floats")
print(f"[ok]  sample[0]     : {outputs[0]:.6f}")
print(f"[ok]  sample[-1]    : {outputs[-1]:.6f}")
PYEOF

echo ""
echo "=== All checks passed — endpoint is ready for Locust load test ==="
echo ""
echo "Next step:"
echo "  export LOCUST_TOKEN=\"${TOKEN}\""
echo "  export LOCUST_VERIFY=false"
echo "  bash run_locust_podman.sh"
