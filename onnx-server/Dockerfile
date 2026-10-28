# =============================================================================
# HOW THIS DOCKERFILE WORKS
#
# The IBM Z Deep Learning Compiler (zDLC) uses ONNX-MLIR to compile your
# .onnx model into a native .so shared library that runs inference via Telum
# (NNPA) hardware on IBM z16/z17/LinuxONE Emperor 4 — NO onnxruntime needed.
#
# TWO MODES — controlled by the ARG USE_ZDLC below:
#
#   OPTION A (USE_ZDLC=true)  — Telum NNPA acceleration via zDLC
#     Requires: model pre-compiled on <KVM_HOST> (see steps below)
#     Result:   ZHigh/ZLow ops execute on Telum AI accelerator
#
#   OPTION B (USE_ZDLC=false) — CPU-only, z16-optimised onnxruntime (default)
#     Requires: nothing extra
#     Result:   CPUExecutionProvider with -march=z16 SIMD optimisation
#
# ─────────────────────────────────────────────────────────────────────────────
# STEPS TO ENABLE TELUM (OPTION A):
#
# STEP 1 — Compile the model on <KVM_HOST> (which has podman):
#
#   podman run --rm \
#     -v /path/to/model:/workdir:z \
#     icr.io/ibmz/zdlc@sha256:04a44c24c774500a402a496efa78e904b9d1e7a41698fd829dd38959a71b5322 \
#     --EmitLib \
#     --maccel=NNPA \
#     -o /workdir/ccf_gru_static \
#     /workdir/ccf_gru_static_tf2onnx_OS_new.onnx
#
#   This produces: ccf_gru_static.so  (Telum-compiled shared library)
#
# STEP 2 — Copy the compiled .so to the bastion build context:
#   scp /path/to/ccf_gru_static.so <USERat><bastion-host>:/root/onnx-server/
#
# STEP 3 — Enable OPTION A in this Dockerfile:
#   On bastion, edit /root/onnx-server/Dockerfile:
#     Change:  ARG USE_ZDLC=false
#     To:      ARG USE_ZDLC=true
#
# STEP 4 — Build and deploy:
#   oc start-build onnx-server -n fraud-detection \
#     --from-dir=/root/onnx-server --follow
#
# STEP 5 — Verify Telum is active in startup logs:
#   Look for: "Inference mode: zDLC NNPA (Telum accelerator)"
# =============================================================================

ARG USE_ZDLC=false

# =============================================================================
# Stage 1 (builder): Compile vanilla onnxruntime from source with z16 flags.
# Used when USE_ZDLC=false (OPTION B).
# NOTE: When USE_ZDLC=true this stage still gets parsed but its layers are
#       never used in the final image — Docker builds all stages regardless.
#       If the source build fails due to transient network errors, just retry.
# =============================================================================
FROM registry.access.redhat.com/ubi9/python-311:latest AS builder

USER root

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

RUN pip install --no-cache-dir \
      wheel \
      setuptools \
      "numpy<2" \
      packaging

ARG ORT_VERSION=1.20.1
RUN git clone --recursive --branch v${ORT_VERSION} --depth 1 \
      https://github.com/microsoft/onnxruntime.git /ort

WORKDIR /ort

RUN sed -i \
      's/be8be39fdbc6e60e94fa7870b280707069b5b81a/32b145f525a8308d7ab1c09388b2e288312d8eba/g' \
      cmake/deps.txt \
    && grep 32b145f5 cmake/deps.txt

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
           CMAKE_TLS_VERIFY=OFF \
           "CMAKE_C_FLAGS=-march=z16 -O3 -funroll-loops" \
           "CMAKE_CXX_FLAGS=-march=z16 -O3 -funroll-loops"

RUN ls /ort/build/Release/dist/

# =============================================================================
# Stage 2 (zdlc): Pull the zDLC image to extract PyRuntimeC and its libs.
# Only pulled when USE_ZDLC=true (OPTION A).
# =============================================================================
FROM icr.io/ibmz/zdlc@sha256:04a44c24c774500a402a496efa78e904b9d1e7a41698fd829dd38959a71b5322 AS zdlc

# =============================================================================
# Stage 3 (runtime): Final serving image.
# =============================================================================
FROM registry.access.redhat.com/ubi9/python-311:latest

ARG USE_ZDLC=false

WORKDIR /app

# -----------------------------------------------------------------------------
# OPTION A — zDLC / Telum NNPA (active when USE_ZDLC=true)
#
# Copies from the zDLC image:
#   - PyRuntimeC.cpython-311-s390x-linux-gnu.so  (Python binding for ONNX-MLIR)
#   - All libabsl_*.so libs that PyRuntimeC depends on
#   - ccf_gru_static.so compiled with --maccel=NNPA --march=z16
#
# The ccf_gru_static.so must be present in the build context
# (/root/onnx-server/ on bastion) before running oc start-build.
# -----------------------------------------------------------------------------
COPY --from=zdlc \
  /usr/local/lib/PyRuntimeC.cpython-311-s390x-linux-gnu.so \
  /app/PyRuntimeC.cpython-311-s390x-linux-gnu.so

COPY --from=zdlc \
  /usr/local/lib/libabsl_bad_any_cast_impl.so \
  /usr/local/lib/libabsl_bad_optional_access.so \
  /usr/local/lib/libabsl_bad_variant_access.so \
  /usr/local/lib/libabsl_base.so \
  /usr/local/lib/libabsl_city.so \
  /usr/local/lib/libabsl_civil_time.so \
  /usr/local/lib/libabsl_cord.so \
  /usr/local/lib/libabsl_cord_internal.so \
  /usr/local/lib/libabsl_cordz_functions.so \
  /usr/local/lib/libabsl_cordz_handle.so \
  /usr/local/lib/libabsl_cordz_info.so \
  /usr/local/lib/libabsl_cordz_sample_token.so \
  /usr/local/lib/libabsl_crc32c.so \
  /usr/local/lib/libabsl_crc_cord_state.so \
  /usr/local/lib/libabsl_crc_cpu_detect.so \
  /usr/local/lib/libabsl_crc_internal.so \
  /usr/local/lib/libabsl_debugging_internal.so \
  /usr/local/lib/libabsl_demangle_internal.so \
  /usr/local/lib/libabsl_die_if_null.so \
  /usr/local/lib/libabsl_examine_stack.so \
  /usr/local/lib/libabsl_exponential_biased.so \
  /usr/local/lib/libabsl_failure_signal_handler.so \
  /usr/local/lib/libabsl_flags_commandlineflag.so \
  /usr/local/lib/libabsl_flags_commandlineflag_internal.so \
  /usr/local/lib/libabsl_flags_config.so \
  /usr/local/lib/libabsl_flags_internal.so \
  /usr/local/lib/libabsl_flags_marshalling.so \
  /usr/local/lib/libabsl_flags_parse.so \
  /usr/local/lib/libabsl_flags_private_handle_accessor.so \
  /usr/local/lib/libabsl_flags_program_name.so \
  /usr/local/lib/libabsl_flags_reflection.so \
  /usr/local/lib/libabsl_flags_usage.so \
  /usr/local/lib/libabsl_flags_usage_internal.so \
  /usr/local/lib/libabsl_graphcycles_internal.so \
  /usr/local/lib/libabsl_hash.so \
  /usr/local/lib/libabsl_hashtablez_sampler.so \
  /usr/local/lib/libabsl_int128.so \
  /usr/local/lib/libabsl_kernel_timeout_internal.so \
  /usr/local/lib/libabsl_leak_check.so \
  /usr/local/lib/libabsl_log_entry.so \
  /usr/local/lib/libabsl_log_flags.so \
  /usr/local/lib/libabsl_log_globals.so \
  /usr/local/lib/libabsl_log_initialize.so \
  /usr/local/lib/libabsl_log_internal_check_op.so \
  /usr/local/lib/libabsl_log_internal_conditions.so \
  /usr/local/lib/libabsl_log_internal_fnmatch.so \
  /usr/local/lib/libabsl_log_internal_format.so \
  /usr/local/lib/libabsl_log_internal_globals.so \
  /usr/local/lib/libabsl_log_internal_log_sink_set.so \
  /usr/local/lib/libabsl_log_internal_message.so \
  /usr/local/lib/libabsl_log_internal_nullguard.so \
  /usr/local/lib/libabsl_log_internal_proto.so \
  /usr/local/lib/libabsl_log_severity.so \
  /usr/local/lib/libabsl_log_sink.so \
  /usr/local/lib/libabsl_low_level_hash.so \
  /usr/local/lib/libabsl_malloc_internal.so \
  /usr/local/lib/libabsl_periodic_sampler.so \
  /usr/local/lib/libabsl_poison.so \
  /usr/local/lib/libabsl_random_distributions.so \
  /usr/local/lib/libabsl_random_internal_platform.so \
  /usr/local/lib/libabsl_random_internal_pool_urbg.so \
  /usr/local/lib/libabsl_random_internal_randen.so \
  /usr/local/lib/libabsl_random_internal_randen_hwaes.so \
  /usr/local/lib/libabsl_random_internal_randen_hwaes_impl.so \
  /usr/local/lib/libabsl_random_internal_randen_slow.so \
  /usr/local/lib/libabsl_random_internal_seed_material.so \
  /usr/local/lib/libabsl_random_seed_gen_exception.so \
  /usr/local/lib/libabsl_random_seed_sequences.so \
  /usr/local/lib/libabsl_raw_hash_set.so \
  /usr/local/lib/libabsl_raw_logging_internal.so \
  /usr/local/lib/libabsl_scoped_set_env.so \
  /usr/local/lib/libabsl_spinlock_wait.so \
  /usr/local/lib/libabsl_stacktrace.so \
  /usr/local/lib/libabsl_status.so \
  /usr/local/lib/libabsl_statusor.so \
  /usr/local/lib/libabsl_str_format_internal.so \
  /usr/local/lib/libabsl_strerror.so \
  /usr/local/lib/libabsl_string_view.so \
  /usr/local/lib/libabsl_strings.so \
  /usr/local/lib/libabsl_strings_internal.so \
  /usr/local/lib/libabsl_symbolize.so \
  /usr/local/lib/libabsl_synchronization.so \
  /usr/local/lib/libabsl_throw_delegate.so \
  /usr/local/lib/libabsl_time.so \
  /usr/local/lib/libabsl_time_zone.so \
  /usr/local/lib/libabsl_utf8_for_code_point.so \
  /usr/local/lib/libabsl_vlog_config_internal.so \
  /app/

# Pre-compiled model .so (built on <KVM_HOST> with --maccel=NNPA --march=z16)
# Must be present in /root/onnx-server/ on bastion before oc start-build.
COPY ccf_gru_static.so* /app/

# -----------------------------------------------------------------------------
# OPTION B — Vanilla z16-optimised onnxruntime (active when USE_ZDLC=false)
# -----------------------------------------------------------------------------
COPY --from=builder /ort/build/Release/dist/*.whl /tmp/

RUN if [ "$USE_ZDLC" = "false" ]; then \
      pip install --no-cache-dir /tmp/onnxruntime*.whl; \
    fi \
    && pip install --no-cache-dir \
         flask==3.0.3 \
         numpy==1.26.4

COPY server.py .

ENV MODEL_DIR=/mnt/models
ENV MODEL_NAME=ccf_gru_static
ENV HTTP_PORT=8080
ENV ORT_INTRA_THREADS=4
ENV ORT_INTER_THREADS=1
# Set to "true" to activate zDLC inference path in server.py
ENV USE_ZDLC=false
# Make /app libs (libabsl_*.so, PyRuntimeC.so) findable without root ldconfig
ENV LD_LIBRARY_PATH=/app

EXPOSE 8080

CMD ["python", "server.py"]
