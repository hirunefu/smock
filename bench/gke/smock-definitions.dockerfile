# Appended to the repository's Dockerfile by scripts/gke-bench.sh to build
# smock's image for the GKE Autopilot run of the release benchmark: the
# release image, with the release binary built on this machine, and the
# benchmark's definition set. The build context holds dist/smock and
# bench/definitions/ as definitions/.
COPY definitions /definitions
ENV SMOCK_DIR=/definitions
