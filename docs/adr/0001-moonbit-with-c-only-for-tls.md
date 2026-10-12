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
- One more exception, decided in [#3](https://github.com/hirunefu/smock/issues/3): a single small C function that calls `setsockopt` (SO_LINGER) so the `reset` Fault can end a connection with an RST. Any other C needs a new ADR.
