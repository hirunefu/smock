# Appended to the repository's Dockerfile by scripts/gke-bench.sh to build
# smock's image for the GKE Autopilot run of the release benchmark: the
# release image, with the release binary built on this machine or by CI,
# the benchmark's definition set, which it serves, and the set's Scenario
# variant, which a variant with the scenarios option serves (SMOCK_DIR in
# its Pod). The build context holds dist/smock, bench/definitions/ as
# definitions/ and bench/definitions-scenarios/ as definitions-scenarios/.
# Like the Dockerfile, it only copies, with no RUN, so that a machine of
# another architecture builds the image with no emulation
# (bench/test_gke.py checks).
COPY definitions /definitions
COPY definitions-scenarios /definitions-scenarios
ENV SMOCK_DIR=/definitions
