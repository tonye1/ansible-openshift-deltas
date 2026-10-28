"""
server.py — KServe v2 REST inference server for ONNX models.

Implements:
  GET  /v2/health/ready
  GET  /v2/health/live
  POST /v2/models/{model_name}/versions/{version}/infer

Model input (ccf_gru_static):
  name="input"  shape=(7, 16, 220)  dtype=float32

Model output:
  shape=(7, 16, 1)  dtype=float32
"""
import os
import glob
import logging
import numpy as np
import onnxruntime as rt
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

MODEL_DIR  = os.environ.get("MODEL_DIR", "/mnt/models")
MODEL_NAME = os.environ.get("MODEL_NAME", "ccf_gru_static")
HTTP_PORT  = int(os.environ.get("HTTP_PORT", "8080"))

# ── Load model at startup ────────────────────────────────────────────────────
def load_model():
    onnx_files = glob.glob(os.path.join(MODEL_DIR, "**", "*.onnx"), recursive=True)
    if not onnx_files:
        raise RuntimeError(f"No .onnx file found under {MODEL_DIR}")
    model_path = onnx_files[0]
    log.info("Loading model: %s", model_path)
    sess_options = rt.SessionOptions()
    sess_options.graph_optimization_level = rt.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = rt.InferenceSession(
        model_path,
        sess_options=sess_options,
        providers=["CPUExecutionProvider"],
    )
    input_name  = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name
    log.info("Model loaded. input=%s output=%s", input_name, output_name)
    return session, input_name, output_name

SESSION, INPUT_NAME, OUTPUT_NAME = load_model()

# ── Health endpoints ─────────────────────────────────────────────────────────
@app.get("/v2/health/ready")
def ready():
    return jsonify({"ready": True})

@app.get("/v2/health/live")
def live():
    return jsonify({"live": True})

# ── Inference endpoint ───────────────────────────────────────────────────────
@app.post("/v2/models/<model_name>/versions/<version>/infer")
def infer(model_name, version):
    body = request.get_json(force=True)

    try:
        inp = body["inputs"][0]
        shape = inp["shape"]                        # e.g. [7, 16, 220]
        dtype_str = inp["datatype"]                 # "FP32"
        flat_data = inp["data"]
    except (KeyError, IndexError) as exc:
        return jsonify({"error": f"Malformed request: {exc}"}), 400

    # Map KServe datatype → numpy dtype
    dtype_map = {"FP32": np.float32, "FP16": np.float16,
                 "INT32": np.int32,  "INT64": np.int64}
    dtype = dtype_map.get(dtype_str)
    if dtype is None:
        return jsonify({"error": f"Unsupported datatype: {dtype_str}"}), 400

    tensor = np.array(flat_data, dtype=dtype).reshape(shape)

    try:
        outputs = SESSION.run([OUTPUT_NAME], {INPUT_NAME: tensor})
    except Exception as exc:                        # pylint: disable=broad-except
        log.exception("Inference error")
        return jsonify({"error": str(exc)}), 500

    result = outputs[0]                             # shape (7, 16, 1)

    return jsonify({
        "model_name": model_name,
        "model_version": version,
        "outputs": [{
            "name":     OUTPUT_NAME,
            "shape":    list(result.shape),
            "datatype": "FP32",
            "data":     result.flatten().tolist(),
        }]
    })

if __name__ == "__main__":
    log.info("Starting ONNX inference server on port %d", HTTP_PORT)
    app.run(host="0.0.0.0", port=HTTP_PORT)
