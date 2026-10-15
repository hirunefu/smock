# Appended to the repository's Dockerfile by scripts/gke-bench.sh to build
# smock's image for the GKE Autopilot run of the release benchmark: the
# release image, with the release binary built on this machine or by CI,
# and the benchmark's definition set. The build context holds dist/smock
# and bench/definitions/ as definitions/. Like the Dockerfile, it only
# copies, with no RUN, so that a machine of another architecture builds the
# image with no emulation (bench/test_gke.py checks).
COPY definitions /definitions
ENV SMOCK_DIR=/definitions
