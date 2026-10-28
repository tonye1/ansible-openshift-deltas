"""
locustfile.py — ccf_gru_static GRU ONNX fraud detection load test
Served by OpenVINO Model Server (OVMS) via Red Hat OpenShift AI on <KVM_HOST>.

Model spec (ccf_220_keras_gru_static-OS.ipynb):
  input  name="input"  shape=(7, 16, 220)  float32
  output               shape=(7, 16, 1)    float32 — fraud P per time step

Cluster: <CLUSTER_DOMAIN>
Bastion: <bastion-host>

This file is used by BOTH:
  - The Podman master container on the bastion (run-master.sh)
  - The OpenShift worker pods (mounted via configmap.yaml)
"""
import os
import numpy as np
from locust import HttpUser, task, between

MODEL_NAME    = "ccf_gru_static"
MODEL_VERSION = "1"
INPUT_NAME    = "input"
TIME_STEPS    = 7
BATCH_SIZE    = 16
FEATURES      = 220

INFER_URL = f"/v2/models/{MODEL_NAME}/versions/{MODEL_VERSION}/infer"

BEARER_TOKEN = os.environ.get("LOCUST_TOKEN", "")


def make_payload():
    data = np.random.rand(TIME_STEPS, BATCH_SIZE, FEATURES).astype(np.float32)
    return {
        "inputs": [{
            "name":     INPUT_NAME,
            "shape":    [TIME_STEPS, BATCH_SIZE, FEATURES],
            "datatype": "FP32",
            "data":     data.flatten().tolist(),
        }]
    }


class FraudModelUser(HttpUser):
    """
    Simulates clients sending 7-transaction sequences to the fraud model.
    Each request is one batch of 16 sequences (shape 7×16×220).
    """
    wait_time = between(0.1, 1.0)

    def on_start(self):
        # <KVM_HOST> uses a self-signed ingress cert
        self.client.verify = False
        if BEARER_TOKEN:
            self.client.headers.update(
                {"Authorization": f"Bearer {BEARER_TOKEN}"}
            )

    @task
    def infer(self):
        with self.client.post(
            INFER_URL,
            json=make_payload(),
            catch_response=True,
            name="/v2/models/ccf_gru_static/infer",
        ) as resp:
            if resp.status_code == 200:
                try:
                    outputs = resp.json()["outputs"][0]["data"]
                    expected = TIME_STEPS * BATCH_SIZE  # 112
                    if len(outputs) != expected:
                        resp.failure(
                            f"Output length {len(outputs)}, expected {expected}"
                        )
                    else:
                        resp.success()
                except (KeyError, ValueError) as exc:
                    resp.failure(f"Bad JSON: {exc}")
            else:
                resp.failure(f"HTTP {resp.status_code}: {resp.text[:200]}")
