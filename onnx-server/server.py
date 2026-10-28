"""
server.py — KServe v2 REST inference server for ONNX models.

Supports two inference backends controlled by the USE_ZDLC env var:

  USE_ZDLC=false (default):
    onnxruntime CPUExecutionProvider, compiled with -march=z16 optimisations.

  USE_ZDLC=true:
    IBM Z Deep Learning Compiler (zDLC / ONNX-MLIR) PyRuntime backend.
    The model .so must have been pre-compiled with --maccel=NNPA and placed
    at /app/ccf_gru_static.so. Inference executes on the Telum NNPA accelerator.

Implements:
  GET  /v2/health/ready
  GET  /v2/health/live
  POST /v2/models/{model_name}/versions/{version}/infer

Model input  (ccf_gru_static): name="input"  shape=(7, 16, 220)  dtype=float32
Model output (ccf_gru_static): name="dense"  shape=(7, 16, 1)    dtype=float32
"""
import os
import sys
import glob
import logging
import numpy as np
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

MODEL_DIR  = os.environ.get("MODEL_DIR", "/mnt/models")
MODEL_NAME = os.environ.get("MODEL_NAME", "ccf_gru_static")
HTTP_PORT  = int(os.environ.get("HTTP_PORT", "8080"))
USE_ZDLC   = os.environ.get("USE_ZDLC", "false").lower() == "true"

# ── Backend selection ────────────────────────────────────────────────────────

def load_zdlc():
    """
    Load the zDLC / ONNX-MLIR PyRuntime backend.
    The compiled model .so is at /app/ccf_gru_static.so.
    PyRuntime.so is at /app/PyRuntime.so (extracted from the zDLC image).
    """
    # Add /app to path so PyRuntimeC.cpython-311-s390x-linux-gnu.so is importable
    if "/app" not in sys.path:
        sys.path.insert(0, "/app")
    try:
        from PyRuntimeC import OMExecutionSession  # noqa: PLC0415
    except ImportError as exc:
        raise RuntimeError(
            "PyRuntimeC.cpython-311-s390x-linux-gnu.so not found at /app — "
            "ensure the Dockerfile was built with USE_ZDLC=true"
        ) from exc

    model_so = "/app/ccf_gru_static.so"
    if not os.path.exists(model_so):
        raise RuntimeError(
            f"Compiled model not found: {model_so} — "
            "run the zDLC compile step and copy the .so into the build context"
        )

    session = OMExecutionSession(model_so)
    log.info("Inference mode: zDLC NNPA (Telum accelerator) — model: %s", model_so)
    return session, "input", "dense"


def load_onnxruntime():
    """
    Load the onnxruntime CPUExecutionProvider backend (z16-optimised build).
    """
    import onnxruntime as rt  # noqa: PLC0415

    onnx_files = glob.glob(os.path.join(MODEL_DIR, "**", "*.onnx"), recursive=True)
    if not onnx_files:
        raise RuntimeError(f"No .onnx file found under {MODEL_DIR}")
    model_path = onnx_files[0]
    log.info("Loading model: %s", model_path)

    so = rt.SessionOptions()
    so.graph_optimization_level = rt.GraphOptimizationLevel.ORT_ENABLE_ALL
    so.intra_op_num_threads = int(os.environ.get("ORT_INTRA_THREADS", "4"))
    so.inter_op_num_threads = int(os.environ.get("ORT_INTER_THREADS", "1"))

    available = rt.get_available_providers()
    log.info("Available execution providers: %s", available)
    providers = ["CPUExecutionProvider"]
    log.info("Inference mode: onnxruntime CPUExecutionProvider (z16-optimised)")

    session = rt.InferenceSession(model_path, sess_options=so, providers=providers)
    input_name  = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name
    log.info("Model loaded. input=%s output=%s", input_name, output_name)
    return session, input_name, output_name


# Load the selected backend at startup
if USE_ZDLC:
    SESSION, INPUT_NAME, OUTPUT_NAME = load_zdlc()
else:
    SESSION, INPUT_NAME, OUTPUT_NAME = load_onnxruntime()

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
        inp       = body["inputs"][0]
        shape     = inp["shape"]
        dtype_str = inp["datatype"]
        flat_data = inp["data"]
    except (KeyError, IndexError) as exc:
        return jsonify({"error": f"Malformed request: {exc}"}), 400

    dtype_map = {"FP32": np.float32, "FP16": np.float16,
                 "INT32": np.int32,  "INT64": np.int64}
    dtype = dtype_map.get(dtype_str)
    if dtype is None:
        return jsonify({"error": f"Unsupported datatype: {dtype_str}"}), 400

    tensor = np.array(flat_data, dtype=dtype).reshape(shape)

    try:
        if USE_ZDLC:
            # PyRuntimeC.OMExecutionSession.run() signature:
            #   run(inputs, shapes, strides) -> list[numpy.ndarray]
            # inputs  — list of C-contiguous input arrays
            # shapes  — list of int64 arrays, one per input (element counts)
            # strides — list of int64 arrays, one per input (element strides,
            #           NOT byte strides — divide numpy strides by itemsize)
            tensor  = np.ascontiguousarray(tensor)
            shapes  = [np.array(tensor.shape, dtype=np.int64)]
            strides = [np.array(
                [s // tensor.itemsize for s in tensor.strides], dtype=np.int64
            )]
            outputs = SESSION.run([tensor], shapes, strides)
            result  = outputs[0]
        else:
            outputs = SESSION.run([OUTPUT_NAME], {INPUT_NAME: tensor})
            result  = outputs[0]
    except Exception as exc:  # pylint: disable=broad-except
        log.exception("Inference error")
        return jsonify({"error": str(exc)}), 500

    return jsonify({
        "model_name":    model_name,
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
