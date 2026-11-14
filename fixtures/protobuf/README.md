# Protobuf fixtures

Descriptor sets and protoc-encoded messages that the tests read. Each is
committed beside the `.proto` files it is built from, so tests never need
protoc, and never check smock's protobuf codec against itself.

`scripts/gen-protobuf-fixtures.sh` rebuilds every one of them, and the
copies of them that tests read elsewhere, from their sources. Run it after
changing a source, and commit what it writes.

## protoc

The committed bytes were built with protoc 36.2 (`libprotoc 36.2`).
`scripts/install-protoc.sh` installs that protoc, for linux/amd64 or
linux/arm64, checked against its pinned SHA-256: protoc into
`<prefix>/bin`, and the well-known types that come with it into
`<prefix>/include`, where protoc finds them. The prefix is `~/.local`
unless you give one. CI installs it the same way.

```sh
scripts/install-protoc.sh
PROTOC=~/.local/bin/protoc scripts/gen-protobuf-fixtures.sh
```

The script runs `$PROTOC`, or else the `protoc` on the `PATH`, which may
be another one, such as a system package's. Another version may write
other bytes, so the script warns when it runs one. With the same version,
two runs write the same bytes. To pin another version, change `version`
and the two digests in `scripts/install-protoc.sh`, then rebuild the
fixtures and commit them; the script reads the version from there.

## The check in CI

On every push, CI runs the script with `--check`
(`.github/workflows/ci.yml`, job `protobuf-fixtures`):

```sh
PROTOC=~/.local/bin/protoc scripts/gen-protobuf-fixtures.sh --check
```

It writes nothing. It builds every file the script writes into a temporary
directory, and fails if a committed file differs or is missing, naming
each. It refuses to run with another protoc than the pinned one. A fixture
added to the script is checked with no change to the job.
`scripts/test-protobuf-fixtures.sh` tests the check on a copy of the
working tree; CI runs it in the same job.

## The fixtures

| Directory | Sources | Built |
|---|---|---|
| `helloworld/` | gRPC's `helloworld.proto`, as `examples/protos/helloworld.proto` is at grpc/grpc commit `d72ce236d8696ae3493d325edd5f33cda39a757f`, and the messages `hello-request.txtpb` and `hello-reply.txtpb` | `greeter.binpb`, its set. The script copies it to `schema/v1/fixtures/body-files/`, and writes it in hex to `greeter_set_test.mbt` in `protobuf/`, `definitions/` and `engine/`. `hello-request.binpb` and `hello-reply.binpb`, the request and reply of a call to `SayHello`, which the script also writes in hex to `protobuf/`. |
| `helloworld-v2/` | The same file, with one more field in `HelloReply` | `greeter.binpb`, its set: the set of `helloworld/` rebuilt with one more field |
| `catalog/` | `catalog.proto`, written for smock's tests of gRPC Stubs, which imports `legacy.proto`, a proto2 file, and `edition.proto`, an editions file. Its methods stream, or reach types that gRPC Stubs serve, and types they do not serve yet. Two messages of its types. | `catalog.binpb`, its set. The script writes it in hex to `catalog_set_test.mbt` in `definitions/` and `protobuf/`. `count-request.binpb` and `count-reply.binpb`, from `count-request.txtpb` and `count-reply.txtpb`, messages with string, bool and int32 fields, which the script also writes in hex to `protobuf/`. |
| `model/` | `shop/orders.proto` (proto3), which imports `shop/common.proto` (proto2) and `shop/legacy.proto` (an edition): every part of the descriptor model | `shop.binpb`, their set. The script writes it in hex to `protobuf/shop_set_test.mbt`. |
| `orders/` | `orders.proto`, which imports `common.proto` | `orders-without-imports.binpb`, the set of `orders.proto` built without `--include_imports`, which lacks `common.proto`. The script copies it to `schema/v1/fixtures/body-files/`. |
| `annotated/` | `annotated.proto`, with comments and custom options, which imports protobuf's `descriptor.proto` | `annotated.binpb`, their set with source info, as `protoc --include_imports --include_source_info` writes it |
| `buf-image/` | Buf's `buf/alpha/image/v1/image.proto`, as it is at bufbuild/buf tag `v1.75.0` (commit `1a3a05a3e0fa350c4b814b7f48aa0e64e9a906bd`), and `greeter.txtpb`, the image that `buf build -o` (1.75.0) writes with its defaults for `helloworld/helloworld.proto`, decoded as text | `greeter.binpb`: that image, with source info and Buf's field 8042 in each file, byte for byte as buf writes it |
| `oneofs/` | `oneofs.proto`, written for smock's tests: a method whose types hold a oneof and a proto3 `optional` field | `oneofs.binpb`, its set. The script writes it in hex to `oneofs_set_test.mbt` in `definitions/` and `protobuf/`. |
| `invalid/` | FileDescriptorSets written as text, which protoc would never write: `twice.txtpb` holds a file twice, `duplicate-name.txtpb` defines a message in two files, and `unresolved.txtpb` names types it does not define | A `.binpb` of each. The script copies `duplicate-name.binpb` to `schema/v1/fixtures/body-files/`. |

## Adding a set

1. Make a directory here for it, and put its `.proto` files in it.
   Imports are found from that directory, and from the well-known types
   that come with protoc.
2. Add a line at the end of the list of fixtures in the script:

   ```sh
   descriptor_set <directory> <set>.binpb <file>.proto...
   ```

   The script builds the set with `protoc --include_imports`, so the set
   holds every file the listed files import. It leaves out source info and
   source-retention options, as protoc does by default. The files are
   named relative to the directory, and the set lists them in the order
   given, so keep that order.

   For other protoc flags, use `build_set` and give the flags first, as
   one argument: `build_set "--include_imports --include_source_info"
   <directory> <set>.binpb <file>.proto...`, or `build_set ""` for a set
   without the files its files import.
3. Run the script.

A set that protoc would never write, such as one that defines a name
twice, is written as text: a `<name>.txtpb` in protobuf's text format,
encoded as a message of type `google.protobuf.FileDescriptorSet` (below),
with `google/protobuf/descriptor.proto` as its `.proto` file, which protoc
finds among the well-known types.

A test that reads no files, such as a test of a protocol module or of a
package that does no I/O, gets a set as a MoonBit constant: add a `hex_test`
line, as for `helloworld/`.

## Adding a message

1. Write the message in protobuf's text format, as
   `<directory>/<name>.txtpb`, beside the `.proto` file of its type.
2. Add a line at the end of the list of fixtures in the script:

   ```sh
   message <directory> <file>.proto <package>.<Type> <name>
   ```

   The script encodes it with `protoc --encode --deterministic_output`,
   into `<directory>/<name>.binpb`.
3. Run the script.

## Licences

Every ticket that adds a fixture follows these rules.

- A `.proto` file taken from another project keeps its licence header.
  One that is changed for smock's tests says so below that header, as
  `helloworld-v2/helloworld.proto` does.
- Files under the Apache License 2.0, such as gRPC's and Buf's, need
  nothing more, since the repository's `LICENSE` holds that licence.
- Files taken from protobuf are under its BSD licence. A directory that
  holds one also holds protobuf's `LICENSE`, beside it.
- So does a directory that holds a set built from one. A set that uses a
  well-known type (`google/protobuf/*.proto`) is such a set, since
  `--include_imports` puts protoc's copy of the type's file in it.
- A copy of such a set that the script writes elsewhere follows the same
  rule: a copied file gets the `LICENSE` beside it, and a `hex_test` file
  names the licence in its header.

Take protobuf's `LICENSE` from the release that protoc comes from:
`https://raw.githubusercontent.com/protocolbuffers/protobuf/v36.2/LICENSE`,
32 lines, SHA-256
`6e5e117324afd944dcf67f36cf329843bc1a92229a8cd9bb573d7a83130fea7d`.
`annotated/` holds one, since its set holds protobuf's
`descriptor.proto`, comments included.
