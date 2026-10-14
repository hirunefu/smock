# The load generator's image for the GKE Autopilot run of the release
# benchmark (scripts/gke-bench.sh): Python, which reads oha's databases as
# bench/bench.py does, the pinned oha of the target architecture
# (scripts/install-oha.sh), and the harness with the plan of the run. The
# build context holds oha, and bench/ with bench.py, requests.json, the
# plan as plan.json, gke/gke.py and gke/generator.py. The base is
# python:3.13-slim (3.13.16 on Debian trixie), pinned by the digest of its
# multi-architecture index. It only copies, with no RUN, so that a machine
# of another architecture builds it with no emulation (bench/test_gke.py
# checks).
FROM python:3.13-slim@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f
COPY --chmod=0755 oha /usr/local/bin/oha
COPY bench /bench
USER 65532:65532
WORKDIR /tmp
ENTRYPOINT ["python3", "-u", "/bench/gke/generator.py"]
