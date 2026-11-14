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
| `helloworld/` | gRPC's `helloworld.proto`, as `examples/protos/helloworld.proto` is at grpc/grpc commit `d72ce236d8696ae3493d325edd5f33cda39a757f` | `greeter.binpb`, its set. The script copies it to `schema/v1/fixtures/body-files/`, and writes it in hex to `greeter_set_test.mbt` in `protobuf/`, `definitions/` and `engine/`. |
| `helloworld-v2/` | The same file, with one more field in `HelloReply` | `greeter.binpb`, its set: the set of `helloworld/` rebuilt with one more field |
| `catalog/` | `catalog.proto`, written for smock's tests of gRPC Stubs, which imports `legacy.proto`, a proto2 file, and `edition.proto`, an editions file. Its methods stream, or reach types that gRPC Stubs serve, and types they do not serve yet. | `catalog.binpb`, its set. The script writes it in hex to `definitions/catalog_set_test.mbt`. |

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
3. Run the script.

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
such as gRPC's, need nothing more, since the repository's `LICENSE` holds
that licence. Files taken from protobuf, which uses a BSD licence, get
protobuf's `LICENSE` beside them and beside their compiled sets.
