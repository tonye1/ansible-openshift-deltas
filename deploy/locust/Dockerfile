# ---------------------------------------------------------------------------
# Dockerfile — Locust load-test image for s390x (IBM Z / <KVM_HOST>)
#
# python:3.11-slim publishes linux/s390x natively.
# g++ is installed to build pyzmq from source (no s390x wheel available).
# After the build stage g++ is not present in the final image.
#
# Build:
#   podman build -t locust-s390x:latest .
#
# Run (headless):
#   podman run --rm --network=host \
#     -v /root/locust:/mnt/locust:z \
#     -e LOCUST_TOKEN=<token> \
#     -e LOCUST_VERIFY=false \
#     locust-s390x:latest \
#       -f /mnt/locust/locustfile.py \
#       --headless --users 10 --spawn-rate 2 --run-time 60s \
#       --host https://ccf-gru-static-predictor-fraud-detection.apps.<CLUSTER_DOMAIN> \
#       --html /mnt/locust/locust-reports/report.html \
#       --csv  /mnt/locust/locust-reports/report
# ---------------------------------------------------------------------------
FROM docker.io/library/python:3.11-slim

# pyzmq bundles libsodium and builds it with CMake + make.
# Both g++ and make must be present; make is not in python:3.11-slim by default.
# Build deps are purged after pip install to keep the final image lean.
RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ make \
 && pip install --no-cache-dir locust \
 && apt-get purge -y --auto-remove g++ make \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["locust"]
