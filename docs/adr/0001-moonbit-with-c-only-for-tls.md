---
status: accepted
---

# Write smock in MoonBit, using C only for TLS

smock is written in MoonBit. We want to use MoonBit and grow its ecosystem, we want a small, fast native binary, and we want the same engine to build for Wasm (browsers, Node.js, WASI, edge platforms). As of 2026-10, MoonBit's official libraries have no production-ready TLS server, no HTTP/2 and no gRPC. So the only C we link is OpenSSL, through FFI, for TLS, ALPN and certificate reloading: we do not write cryptography ourselves. The protocol layers (HTTP/1.1, HTTP/2, gRPC, WebSocket) are written in MoonBit as packages independent of I/O, so they can be reused outside smock. Wasm builds use no C at all, because the host provides networking and TLS there.

## Considered Options

- **Rust or Go.** Mature HTTP/2, TLS and gRPC stacks, and multi-core runtimes. Rejected because building smock is also meant to exercise and grow MoonBit, and because one engine should also build for Wasm.
- **MoonBit, with C used widely (e.g. nghttp2 for HTTP/2).** Faster to a first release, but most of the native server would then be C, and static linking and distribution would get harder.
- **Engine in MoonBit, native server in Rust embedding it.** Keeps a mature server stack, but means maintaining two languages and a boundary between them.

## Consequences

- MoonBit is pre-1.0 and has breaking changes every month, so we expect to keep up with language and library changes.
- The official async runtime is single-threaded, so one process uses one core and we scale by adding Pods (ADR 0003).
- HTTP/1.1, HTTP/2, gRPC framing and WebSocket are ours to build and maintain. That is why the first release is limited to HTTP/1.1, HTTPS and SSE.
- Running Wasm plugins inside the native server needs an embedded Wasm runtime (Wasmtime or Extism, both C APIs). We accept that as a planned exception to "C only for TLS"; which runtime to embed is decided when plugins are designed.
- One more exception, decided in [#3](https://github.com/hirunefu/smock/issues/3): a single small C function that calls `setsockopt` (SO_LINGER) so the `reset` Fault can end a connection with an RST. Its limits: it is one OS call and no new library; it is in the native server only (`server/reset.c`), never in the packages that decide a response or in the protocol modules, which do no I/O; and Wasm builds are unaffected, because the engine only plans the Fault and the host carries it out. Any other C needs a new ADR. `scripts/check-no-c.sh` and `scripts/check-no-io.sh` check these limits.

## Follow-up, 2026-10-23

HTTP/2 ([#133](https://github.com/hirunefu/smock/issues/133)) takes its framing, HPACK header compression and connection state from the `http2` package of moonbitstack/moonhttp, a third-party MoonBit module, as [ADR 0005](0005-http2-comes-from-moonhttp.md) records. This narrows one statement above: HTTP/1.1, gRPC framing and WebSocket are still ours to build and maintain, but HTTP/2's framing, HPACK and connection state are not. smock keeps the rest of HTTP/2: the sockets and TLS, telling HTTP/2 from HTTP/1.1, mapping each stream onto the engine's request, the concurrency of streams, Faults, limits, timeouts and the denial-of-service defences. There is no smock HTTP/2 module to publish. moonhttp is MoonBit, does no I/O and has no C, so the decision, C only for TLS, is unchanged. The packages that decide a response never import it, so `scripts/check-no-io.sh` is unchanged too. To keep moonhttp and the modules it imports free of C, the same spec has `scripts/check-no-c.sh` also scan the resolved dependencies, in CI. gRPC and WebSocket decide their own. This note does not change the decision.
