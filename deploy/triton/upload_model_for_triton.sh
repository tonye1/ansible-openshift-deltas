#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# upload_model_for_triton.sh
#
# Uploads the ccf_gru_static ONNX model to MinIO in the Triton model
# repository format using only curl + Python (AWS Signature V4).
#
# NO oc cp, NO mc client, NO tar required.
# Uses the MinIO HTTPS Route directly from the bastion.
#
# Triton model repository layout created in MinIO:
#   s3://models/triton-ccf-gru-static/
#     ccf_gru_static/
#       config.pbtxt
#       1/
#         model.onnx
#
# Prerequisites (all already present on <BASTION_HOSTNAME>):
#   - curl
#   - python3
#   - oc logged in to the cluster
#   - MinIO already deployed and its Route is up
#   - ONNX file at ~/onnx-server/ccf_gru_static_tf2onnx_OS_new.onnx
#   - config.pbtxt at ~/deploy/triton/ccf_gru_static/config.pbtxt
#
# Usage (run on bastion):
#   bash ~/deploy/triton/upload_model_for_triton.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ONNX_FILE="${HOME}/onnx-server/ccf_gru_static_tf2onnx_OS_new.onnx"
CONFIG_FILE="${HOME}/deploy/triton/ccf_gru_static/config.pbtxt"
MINIO_ENDPOINT="https://minio-api-minio.apps.<CLUSTER_DOMAIN>"
MINIO_ACCESS_KEY="<MINIO_USER>"
MINIO_SECRET_KEY="<MINIO_PASSWORD>"
BUCKET="models"
TRITON_PREFIX="triton-ccf-gru-static"

# ── helper: PUT a file to MinIO using AWS Signature V4 via Python ──────────
s3_put() {
  local src_file="$1"
  local s3_key="$2"
  python3 - "$src_file" "$s3_key" <<'PYEOF'
import sys, os, hmac, hashlib, datetime, subprocess

src   = sys.argv[1]
key   = sys.argv[2]

endpoint   = os.environ['MINIO_ENDPOINT'].rstrip('/')
access_key = os.environ['MINIO_ACCESS_KEY']
secret_key = os.environ['MINIO_SECRET_KEY']
bucket     = os.environ['BUCKET']

with open(src, 'rb') as f:
    body = f.read()

content_hash = hashlib.sha256(body).hexdigest()
now = datetime.datetime.utcnow()
datestamp  = now.strftime('%Y%m%d')
amzdate    = now.strftime('%Y%m%dT%H%M%SZ')
region     = 'us-east-1'
service    = 's3'

# Canonical request
method          = 'PUT'
canonical_uri   = f'/{bucket}/{key}'
canonical_qs    = ''
signed_headers  = 'host;x-amz-content-sha256;x-amz-date'

host = endpoint.replace('https://', '').replace('http://', '')
canonical_headers = (
    f'host:{host}\n'
    f'x-amz-content-sha256:{content_hash}\n'
    f'x-amz-date:{amzdate}\n'
)

canonical_request = '\n'.join([
    method, canonical_uri, canonical_qs,
    canonical_headers, signed_headers, content_hash
])

# String to sign
credential_scope = f'{datestamp}/{region}/{service}/aws4_request'
string_to_sign = '\n'.join([
    'AWS4-HMAC-SHA256', amzdate, credential_scope,
    hashlib.sha256(canonical_request.encode()).hexdigest()
])

# Signing key
def hmac_sha256(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()

signing_key = hmac_sha256(
    hmac_sha256(
        hmac_sha256(
            hmac_sha256(('AWS4' + secret_key).encode(), datestamp),
            region),
        service),
    'aws4_request')

signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

auth = (
    f'AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope},'
    f'SignedHeaders={signed_headers},Signature={signature}'
)

url = f'{endpoint}/{bucket}/{key}'

result = subprocess.run([
    'curl', '-sk', '-X', 'PUT',
    '-H', f'Host: {host}',
    '-H', f'x-amz-date: {amzdate}',
    '-H', f'x-amz-content-sha256: {content_hash}',
    '-H', f'Authorization: {auth}',
    '-H', 'Content-Type: application/octet-stream',
    '--data-binary', f'@{src}',
    '-w', '\n%{http_code}',
    url
], capture_output=True, text=True)

output = result.stdout.strip()
lines  = output.split('\n')
status = lines[-1]
body   = '\n'.join(lines[:-1])

if status in ('200', '201', '204', '200'):
    print(f'  OK ({status}): {key}')
else:
    print(f'  FAILED ({status}): {key}')
    if body:
        print(f'  Response: {body[:300]}')
    sys.exit(1)
PYEOF
}

export MINIO_ENDPOINT MINIO_ACCESS_KEY MINIO_SECRET_KEY BUCKET

# ── 1. Verify source files ──────────────────────────────────────────────────
echo "==> Checking source files..."
[[ -f "${ONNX_FILE}" ]]   || { echo "ERROR: ONNX file not found: ${ONNX_FILE}"; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "ERROR: config.pbtxt not found: ${CONFIG_FILE}"; exit 1; }
echo "  ONNX model : ${ONNX_FILE}  ($(du -h "${ONNX_FILE}" | cut -f1))"
echo "  config     : ${CONFIG_FILE}"

# ── 2. Verify MinIO Route is reachable ────────────────────────────────────
echo ""
echo "==> Checking MinIO endpoint ${MINIO_ENDPOINT} ..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${MINIO_ENDPOINT}/minio/health/ready")
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: MinIO health check returned HTTP ${HTTP_CODE}"
  echo "Check: oc get pods -n minio && oc get route -n minio"
  exit 1
fi
echo "  MinIO is healthy (HTTP 200)"

# ── 3. Create bucket (PUT with no body creates bucket on MinIO) ───────────
echo ""
echo "==> Creating bucket '${BUCKET}' (idempotent)..."
python3 - <<PYEOF
import os, hmac, hashlib, datetime, subprocess

endpoint   = os.environ['MINIO_ENDPOINT'].rstrip('/')
access_key = os.environ['MINIO_ACCESS_KEY']
secret_key = os.environ['MINIO_SECRET_KEY']
bucket     = os.environ['BUCKET']

body = b''
content_hash = hashlib.sha256(body).hexdigest()
now        = datetime.datetime.utcnow()
datestamp  = now.strftime('%Y%m%d')
amzdate    = now.strftime('%Y%m%dT%H%M%SZ')
region     = 'us-east-1'; service = 's3'
host       = endpoint.replace('https://','').replace('http://','')

canonical_headers = f'host:{host}\nx-amz-content-sha256:{content_hash}\nx-amz-date:{amzdate}\n'
signed_headers    = 'host;x-amz-content-sha256;x-amz-date'
canonical_request = f'PUT\n/{bucket}\n\n{canonical_headers}\n{signed_headers}\n{content_hash}'

credential_scope = f'{datestamp}/{region}/{service}/aws4_request'
string_to_sign   = f'AWS4-HMAC-SHA256\n{amzdate}\n{credential_scope}\n' + hashlib.sha256(canonical_request.encode()).hexdigest()

def hsha(k,m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
sk = hsha(hsha(hsha(hsha(('AWS4'+secret_key).encode(),datestamp),region),service),'aws4_request')
sig = hmac.new(sk, string_to_sign.encode(), hashlib.sha256).hexdigest()
auth = f'AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope},SignedHeaders={signed_headers},Signature={sig}'

r = subprocess.run(['curl','-sk','-X','PUT',
  '-H',f'Host:{host}','-H',f'x-amz-date:{amzdate}',
  '-H',f'x-amz-content-sha256:{content_hash}','-H',f'Authorization:{auth}',
  '-w','\n%{http_code}', f'{endpoint}/{bucket}'], capture_output=True, text=True)

code = r.stdout.strip().split('\n')[-1]
# 200=ok, 409=already exists — both are fine
if code in ('200','201','204','409'):
    print(f'  Bucket ready (HTTP {code})')
else:
    print(f'  WARNING: bucket create returned HTTP {code}: {r.stdout[:200]}')
PYEOF

# ── 4. Upload config.pbtxt ──────────────────────────────────────────────────
echo ""
echo "==> Uploading config.pbtxt..."
s3_put "${CONFIG_FILE}" "${TRITON_PREFIX}/ccf_gru_static/config.pbtxt"

# ── 5. Upload model.onnx ────────────────────────────────────────────────────
echo ""
echo "==> Uploading model.onnx (2 MB — takes a few seconds)..."
s3_put "${ONNX_FILE}" "${TRITON_PREFIX}/ccf_gru_static/1/model.onnx"

# ── 6. Verify layout via S3 LIST ────────────────────────────────────────────
echo ""
echo "==> Verifying MinIO layout..."
python3 - <<PYEOF
import os, hmac, hashlib, datetime, subprocess, re

endpoint   = os.environ['MINIO_ENDPOINT'].rstrip('/')
access_key = os.environ['MINIO_ACCESS_KEY']
secret_key = os.environ['MINIO_SECRET_KEY']
bucket     = os.environ['BUCKET']
prefix     = os.environ.get('TRITON_PREFIX','triton-ccf-gru-static')

body = b''
content_hash = hashlib.sha256(body).hexdigest()
now        = datetime.datetime.utcnow()
datestamp  = now.strftime('%Y%m%d')
amzdate    = now.strftime('%Y%m%dT%H%M%SZ')
region     = 'us-east-1'; service = 's3'
host       = endpoint.replace('https://','').replace('http://','')

qs = f'list-type=2&prefix={prefix}%2F'
canonical_headers = f'host:{host}\nx-amz-content-sha256:{content_hash}\nx-amz-date:{amzdate}\n'
signed_headers    = 'host;x-amz-content-sha256;x-amz-date'
canonical_request = f'GET\n/{bucket}\n{qs}\n{canonical_headers}\n{signed_headers}\n{content_hash}'

credential_scope = f'{datestamp}/{region}/{service}/aws4_request'
string_to_sign   = f'AWS4-HMAC-SHA256\n{amzdate}\n{credential_scope}\n' + hashlib.sha256(canonical_request.encode()).hexdigest()

def hsha(k,m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
sk = hsha(hsha(hsha(hsha(('AWS4'+secret_key).encode(),datestamp),region),service),'aws4_request')
sig = hmac.new(sk, string_to_sign.encode(), hashlib.sha256).hexdigest()
auth = f'AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope},SignedHeaders={signed_headers},Signature={sig}'

r = subprocess.run(['curl','-sk','-X','GET',
  '-H',f'Host:{host}','-H',f'x-amz-date:{amzdate}',
  '-H',f'x-amz-content-sha256:{content_hash}','-H',f'Authorization:{auth}',
  f'{endpoint}/{bucket}?{qs}'], capture_output=True, text=True)

keys = re.findall(r'<Key>([^<]+)</Key>', r.stdout)
for k in keys:
    print(f'  {k}')
if not keys:
    print('  WARNING: no objects found — check credentials/bucket')
PYEOF

export TRITON_PREFIX

echo ""
echo "==> Done. MinIO Triton model repository layout:"
echo "    s3://${BUCKET}/${TRITON_PREFIX}/"
echo "      ccf_gru_static/"
echo "        config.pbtxt"
echo "        1/"
echo "          model.onnx"
echo ""
echo "Next steps:"
echo "  1. oc apply -f ~/deploy/triton/triton-serving-runtime.yaml"
echo "  2. oc apply -f ~/deploy/triton/triton-inferenceservice.yaml"
echo "  3. oc get pods -n fraud-detection -w"
echo "  4. oc logs -n fraud-detection -l serving.kserve.io/inferenceservice=ccf-gru-static-triton -c kserve-container -f"
