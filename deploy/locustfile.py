"""
locustfile.py — Load test for the ccf_gru_static GRU ONNX model
served by the custom onnx-server runtime on Red Hat OpenShift AI.

Model input spec (from tf2onnx conversion in ccf_220_keras_gru_static-OS.ipynb):
  name  : "input"
  shape : (7, 16, 220)   — [time_steps, batch_size, features]  float32

KServe v2 inference protocol endpoint:
  POST /v2/models/<model_name>/versions/<version>/infer

Usage
-----
# Install dependencies (numpy is NOT required — stdlib random is used instead)
pip install locust

# Run headless for 60 s at 10 users, 2 spawn rate
export LOCUST_TOKEN=$(oc whoami -t)
export LOCUST_VERIFY=false          # self-signed TLS on KVM

locust -f locustfile.py \
  --headless \
  --users 10 \
  --spawn-rate 2 \
  --run-time 60s \
  --host https://ccf-gru-static-predictor-fraud-detection.apps.<CLUSTER_DOMAIN> \
  --html locust-report-baseline.html \
  --csv  locust-report-baseline

# Or open the web UI (default http://localhost:8089)
locust -f locustfile.py \
  --host https://ccf-gru-static-predictor-fraud-detection.apps.<CLUSTER_DOMAIN>

Environment variables
---------------------
LOCUST_TOKEN   : OpenShift bearer token (required — route is auth-protected)
LOCUST_VERIFY  : set to "false" to skip TLS verification (self-signed certs on KVM)
"""

import os
import json
import random
import logging
from locust import HttpUser, task, between, events

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Model constants (must match the ONNX spec)
# ---------------------------------------------------------------------------
MODEL_NAME   = "ccf_gru_static"
MODEL_VERSION = "1"
INPUT_NAME   = "input"
TIME_STEPS   = 7
BATCH_SIZE   = 16
FEATURES     = 220

INFER_URL    = f"/v2/models/{MODEL_NAME}/versions/{MODEL_VERSION}/infer"

# ---------------------------------------------------------------------------
# Auth / TLS helpers
# ---------------------------------------------------------------------------
BEARER_TOKEN = os.environ.get("LOCUST_TOKEN", "")
VERIFY_TLS   = os.environ.get("LOCUST_VERIFY", "true").lower() not in ("false", "0", "no")

# ---------------------------------------------------------------------------
# Payload builder
# ---------------------------------------------------------------------------

# Pre-compute the flat data length once to avoid per-request multiplication.
_N = TIME_STEPS * BATCH_SIZE * FEATURES   # 24 640


def make_payload() -> dict:
    """
    Build a single KServe v2 inference request.

    The model was exported with:
        spec = (tf.TensorSpec((7, 16, 220), tf.float32, name="input"),)
    so the flat data array has 7 * 16 * 220 = 24 640 float32 values.

    Uses stdlib random — numpy is not required on the bastion host.
    """
    return {
        "inputs": [
            {
                "name":     INPUT_NAME,
                "shape":    [TIME_STEPS, BATCH_SIZE, FEATURES],
                "datatype": "FP32",
                "data":     [random.random() for _ in range(_N)],
            }
        ]
    }


# ---------------------------------------------------------------------------
# Locust user
# ---------------------------------------------------------------------------

class FraudModelUser(HttpUser):
    """
    Simulates a client sending credit-card transaction sequences to the
    GRU fraud-detection model endpoint.

    wait_time: pause between 0.1 s and 1 s between requests per user.
    Adjust --users and --spawn-rate on the CLI to control concurrency.
    """
    wait_time = between(0.1, 1.0)

    def on_start(self):
        """Called once when a simulated user starts."""
        if BEARER_TOKEN:
            self.client.headers.update(
                {"Authorization": f"Bearer {BEARER_TOKEN}"}
            )
        # Disable SSL verification for self-signed KVM certs when requested
        if not VERIFY_TLS:
            self.client.verify = False

    @task
    def infer(self):
        payload = make_payload()
        with self.client.post(
            INFER_URL,
            json=payload,
            catch_response=True,
            name="/v2/models/ccf_gru_static/infer",
        ) as response:
            if response.status_code == 200:
                try:
                    body = response.json()
                    # OVMS v2 response: outputs[0].data has shape (7, 16, 1)
                    # The last time step [-1] is the fraud probability per sample
                    outputs = body["outputs"][0]["data"]
                    n_values = TIME_STEPS * BATCH_SIZE  # 112
                    if len(outputs) != n_values:
                        response.failure(
                            f"Unexpected output length: {len(outputs)} (expected {n_values})"
                        )
                    else:
                        response.success()
                except (KeyError, ValueError) as exc:
                    response.failure(f"Bad JSON: {exc}")
            else:
                msg = f"HTTP {response.status_code}: {response.text[:400]}"
                log.error("Inference failed — %s", msg)
                response.failure(msg)


# ---------------------------------------------------------------------------
# Optional: print a fraud-score summary at the end of the test run
# ---------------------------------------------------------------------------

@events.quitting.add_listener
def on_quitting(environment, **kwargs):
    print("\n[ccf-gru-locust] Test complete.")
    print(f"  Total requests : {environment.stats.total.num_requests}")
    print(f"  Failures       : {environment.stats.total.num_failures}")
    rps = environment.stats.total.current_rps
    print(f"  Current RPS    : {rps:.1f}")
