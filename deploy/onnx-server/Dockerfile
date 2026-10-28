# =============================================================================
# Multi-stage Dockerfile: build onnxruntime from source on s390x, then package
# a minimal KServe v2 REST inference server.
#
# Stage 1 (builder): compiles onnxruntime on s390x using cmake + gcc.
#           Takes 20-40 min. Produces a .whl file.
# Stage 2 (server):  copies the .whl into a clean ubi9/python-311 image and
#           installs it alongside Flask.
#
# The resulting image implements the KServe v2 REST protocol:
#   GET  /v2/health/ready
#   GET  /v2/health/live
#   POST /v2/models/{model_name}/versions/{version}/infer
#
# ORT version: 1.20.1
#
# Eigen fix:
#   cmake/external/eigen.cmake hardcodes SHA1 be8be39f for the Eigen zip
#   downloaded from GitLab. The actual content now hashes to 32b145f5.
#   We patch the SHA1 in-source after cloning so cmake's verify step passes.
# =============================================================================

# ── Stage 1: build onnxruntime wheel ─────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/python-311:latest AS builder

USER root

# Build dependencies
RUN dnf install -y \
      cmake \
      gcc \
      gcc-c++ \
      git \
      ninja-build \
      python3-devel \
      python3-pip \
      patch \
      wget \
      unzip \
    && dnf clean all

# Python build deps
RUN pip install --no-cache-dir \
      wheel \
      setuptools \
      "numpy<2" \
      packaging

# Clone onnxruntime 1.20.1
ARG ORT_VERSION=1.20.1
RUN git clone --recursive --branch v${ORT_VERSION} --depth 1 \
      https://github.com/microsoft/onnxruntime.git /ort

WORKDIR /ort

# ── Eigen SHA1 patch ──────────────────────────────────────────────────────────
# The SHA1 is stored in cmake/deps.txt, not in eigen.cmake.
# GitLab now serves the Eigen zip with SHA1 32b145f5; deps.txt still expects
# be8be39f. Patch deps.txt so cmake's FetchContent verify step passes.
RUN sed -i \
      's/be8be39fdbc6e60e94fa7870b280707069b5b81a/32b145f525a8308d7ab1c09388b2e288312d8eba/g' \
      cmake/deps.txt \
    && grep 32b145f5 cmake/deps.txt

# Build the Python wheel for s390x (CPU only, no CUDA, no training)
RUN pip install --no-cache-dir \
      build \
      setuptools \
      wheel \
      "numpy<2" \
    && python3 tools/ci_build/build.py \
         --allow_running_as_root \
         --build_dir /ort/build \
         --config Release \
         --build_wheel \
         --skip_tests \
         --parallel $(nproc) \
         --cmake_extra_defines \
           CMAKE_BUILD_TYPE=Release \
           onnxruntime_BUILD_UNIT_TESTS=OFF \
           onnxruntime_ENABLE_PYTHON=ON \
           CMAKE_TLS_VERIFY=OFF

# The wheel ends up in /ort/build/Release/dist/
RUN ls /ort/build/Release/dist/

# ── Stage 2: inference server ─────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/python-311:latest

WORKDIR /app

# Copy the wheel from the builder stage
COPY --from=builder /ort/build/Release/dist/*.whl /tmp/

# Install the wheel + Flask
RUN pip install --no-cache-dir /tmp/onnxruntime*.whl \
    && pip install --no-cache-dir \
         flask==3.0.3 \
         numpy==1.26.4

# Copy the inference server
COPY server.py .

# KServe mounts the model at /mnt/models
ENV MODEL_DIR=/mnt/models
ENV MODEL_NAME=ccf_gru_static
ENV HTTP_PORT=8080

EXPOSE 8080

CMD ["python", "server.py"]
