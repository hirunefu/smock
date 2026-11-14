# Protobuf fixtures

Descriptor sets and protoc-encoded messages that the tests read. Each is
committed beside the `.proto` files it is built from, so tests never need
protoc, and never check smock's protobuf codec against itself.

`scripts/gen-protobuf-fixtures.sh` rebuilds every one of them, and the
copies of them that tests read elsewhere, from their sources. Run it after
changing a source, and commit what it writes:

```sh
mise exec protoc@36.2 -- scripts/gen-protobuf-fixtures.sh
```

It runs `$PROTOC`, or else the `protoc` on the `PATH`. The committed bytes
were built with protoc 36.2 (`libprotoc 36.2`). Another version may write
other bytes, so the script warns when it runs one. With the same version,
two runs write the same bytes.

## The fixtures

| Directory | Sources | Built |
|---|---|---|
| `helloworld/` | gRPC's `helloworld.proto`, as `examples/protos/helloworld.proto` is at grpc/grpc commit `d72ce236d8696ae3493d325edd5f33cda39a757f` | `greeter.binpb`, its set. The script copies it to `schema/v1/fixtures/body-files/`, and writes it in hex to `protobuf/greeter_set_test.mbt`. |
| `helloworld-v2/` | The same file, with one more field in `HelloReply` | `greeter.binpb`, its set: the set of `helloworld/` rebuilt with one more field |
| `model/` | `shop/orders.proto` (proto3), which imports `shop/common.proto` (proto2) and `shop/legacy.proto` (an edition): every part of the descriptor model | `shop.binpb`, their set. The script writes it in hex to `protobuf/shop_set_test.mbt`. |
| `orders/` | `orders.proto`, which imports `common.proto` | `orders-without-imports.binpb`, the set of `orders.proto` built without `--include_imports`, which lacks `common.proto`. The script copies it to `schema/v1/fixtures/body-files/`. |
| `annotated/` | `annotated.proto`, with comments and custom options, which imports protobuf's `descriptor.proto` | `annotated.binpb`, their set with source info, as `protoc --include_imports --include_source_info` writes it |
| `buf-image/` | Buf's `buf/alpha/image/v1/image.proto`, as it is at bufbuild/buf tag `v1.75.0` (commit `1a3a05a3e0fa350c4b814b7f48aa0e64e9a906bd`), and `greeter.txtpb`, the image that `buf build -o` (1.75.0) writes with its defaults for `helloworld/helloworld.proto`, decoded as text | `greeter.binpb`: that image, with source info and Buf's field 8042 in each file, byte for byte as buf writes it |
| `invalid/` | FileDescriptorSets written as text, which protoc would never write: `twice.txtpb` holds a file twice, `duplicate-name.txtpb` defines a message in two files, and `unresolved.txtpb` names types it does not define | A `.binpb` of each. The script copies `duplicate-name.binpb` to `schema/v1/fixtures/body-files/`. |

## Adding a set

1. Make a directory here for it, and put its `.proto` files in it.
   Imports are found from that directory, and from the well-known types
   that come with protoc.
2. Add a line to the end of the script:

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
2. Add a line to the end of the script:

   ```sh
   message <directory> <file>.proto <package>.<Type> <name>
   ```

   The script encodes it with `protoc --encode --deterministic_output`,
   into `<directory>/<name>.binpb`.
3. Run the script.

## Licences

A `.proto` file taken from another project keeps its licence header. One
that is changed for smock's tests says so below that header, as
`helloworld-v2/helloworld.proto` does. Files under the Apache License 2.0,
such as gRPC's and Buf's, need nothing more, since the repository's
`LICENSE` holds that licence. Files taken from protobuf, which uses a BSD
licence, get protobuf's `LICENSE` beside them and beside their compiled
sets, as `LICENSE-protobuf`. `annotated/` has one, since its set holds
protobuf's `descriptor.proto`, comments included: it is protobuf's
`LICENSE` as it is at tag `v36.2`.
