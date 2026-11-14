# Definition-file fixtures

`scripts/check-schema.sh` checks every file here twice, each alone in a
definitions directory: with an external JSON Schema validator against
`../definitions.json`, and with `smock check`. Both verdicts must match the
directory the file is in, so CI fails as soon as smock and the Schema
disagree.

| Directory | The Schema | smock |
|---|---|---|
| `valid/` | accepts it | accepts it |
| `invalid/` | rejects it | rejects it |
| `invalid-beyond-schema/` | accepts it | rejects it, for a reason the Schema cannot see |

- `invalid-beyond-schema/` holds files that break a rule the Schema cannot
  express, such as a rule across the Mocks and files of a definition set:
  duplicate Mock names or Stub IDs, two Mocks that claim the same Host
  after normalisation, more than one Mock marked `default`, or a Stub that
  names a Mock no file declares.
  Files that are invalid only because of an RE2 pattern, a missing body
  file, a uniform delay or wait whose `min` exceeds its `max`, or a Host
  that no request can carry (such as `:8080`, which normalises to no name, or
  `users:http`) belong here too, as do a response's or a `noMatch`'s
  `headers` that give two names that differ only in case, and JSON files
  that repeat a key in one object, which a JSON Schema validator reads as
  the last of them.
  So do a `json` condition with an unknown `$` key, or with an operator
  beside another key: the Schema leaves the `json` value open, because any
  literal JSON is valid there. So does an `xml` condition with a path that
  does not compile: the Schema checks only that a path starts with `/`.
  So do two tool calls of one `llm` with the same `id`: the Schema cannot
  say that a member differs across the elements of a list. So does an
  `llm` error whose `after` passes the end of the text, which the Schema
  cannot count, and an `llm` as written whose JSON reply or stream takes
  more than 1 MiB once encoded, which the Schema cannot measure. That
  includes one whose stream a declared error ends early, so that only its
  JSON reply passes the bound.
  Data buckets break such rules too: a bucket that names a Mock no file
  declares, two buckets of one Mock with the same name, a `jsonFile` that
  is missing or does not hold JSON in UTF-8, a keyed bucket whose value is
  not an array of objects with valid, unique keys, and a template that
  reads a bucket its Mock does not declare. So do writes of `dataWrites`: a
  write to a bucket its Mock does not declare, `key` on a bucket without
  `key`, `merge` without `key` on a keyed bucket, a literal `merge` value
  that is not an object, and a literal value that breaks a keyed bucket's
  rules, such as an item that is not an object, an item of `set` or `merge`
  with `key` whose key member holds no key, or one whose key member holds a
  key other than the literal `key`. So do CRUD Stubs: a `crud.bucket` that
  its Mock does not declare, or that has no `key`, and `crud.headers` that
  give two names that differ only in case.
  So do rules that depend on whether a Stub is a gRPC Stub, which the
  Schema cannot see, since a Stub is one when its exact path names a method
  of its Mock's Descriptor set: an HTTP Stub's response without `status`,
  an HTTP Stub's response that gives `grpc`, a gRPC Stub on a streaming
  method, and a gRPC Stub's `json` condition with a key that names no
  field of the method's input type.

A field joins the Schema only together with smock's support for it, so no
fixture is accepted by the Schema and rejected by smock for a field smock
lacks.

Each definitions directory also gets the files under `body-files/` as its
body-file subdirectory (`files/`, the default), so a fixture can refer to
`users/1.json` with `bodyFile`, to `orders.json` with a Data bucket's
`jsonFile`, or to `greeter.binpb`, the Descriptor set of gRPC's
`helloworld.proto`, with a Mock's `grpc.descriptorSet`. A fixture whose
`bodyFile`, `jsonFile` or `descriptorSet` names a file that is not there
belongs in `invalid-beyond-schema/`, as does one whose `descriptorSet` names
a file that does not decode as a Descriptor set, or a set that smock
refuses: `orders-without-imports.binpb`, which lacks a file it imports, and
`duplicate-name.binpb`, in which two files define one message.
`greeter.binpb` and those two sets are copies that
`scripts/gen-protobuf-fixtures.sh` writes (`fixtures/protobuf/README.md`).

Adding a fixture is adding a file, named after what it shows and ending in
`.json`, `.yaml` or `.yml`. `valid/users-from-jsonnet.json` is exported from
the Jsonnet example in `docs/definition-files.md`.
