# The smock container image. It packs a binary already built natively on the
# machine that builds the image (scripts/build-release.sh writes dist/smock),
# so the image holds exactly the release binary of its architecture. Nothing
# is compiled here. See .github/workflows/release.yml.
#
# The base is distroless and provides what the binary links dynamically:
# glibc and OpenSSL 3, which smock uses for TLS. It has no shell and no
# package manager. It is pinned by the digest of its multi-architecture
# index; scripts/smoke-test-image.sh checks that smock is the only file this
# image adds to it.
FROM gcr.io/distroless/base-debian13:nonroot@sha256:a0d70d6a97cd697d9362bc2aae4a6560dd65817e365d0043b07325a97975dc91

LABEL org.opencontainers.image.title="smock" \
      org.opencontainers.image.description="A mock server for HTTP/1.1, HTTPS and Server-Sent Events" \
      org.opencontainers.image.source="https://github.com/hirunefu/smock" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --chmod=0755 dist/smock /usr/local/bin/smock

# The base's nonroot user, by number, so that Kubernetes can check
# runAsNonRoot. smock writes nothing to the filesystem, so the root
# filesystem can be read-only.
USER 65532:65532

# Plain, TLS and admin ports.
EXPOSE 8080 8443 9090

ENTRYPOINT ["/usr/local/bin/smock"]
CMD ["serve"]
