# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- `smock import-openapi` converts an OpenAPI 3.0, 3.1 or 3.2 document
  into a Definition file, once. Each operation becomes Stubs that match
  its method and path. By default, they answer its main status. Parts
  that it does not import, such as callbacks, are left out with a warning.
  smock never reads OpenAPI when it serves. See
  [docs/importing-openapi.md](docs/importing-openapi.md).
- The quick start of [docs/importing-openapi.md](docs/importing-openapi.md)
  imports an example beside the Mockoon one, in
  `docs/examples/from-openapi/`: a small OpenAPI document with a server
  path, a templated path, named examples and a 404, and the file that its
  import writes. smock's tests import it, the Admin API's own document and
  the OAI's Petstore again, and compare each result with its committed
  file, so every change to what the import writes shows up in review.
- `smock import-openapi` turns a path with parameters, such as
  `/pets/{petId}`, into a pattern in which each parameter matches text
  within one segment, and keeps a path without parameters exact. A
  concrete path comes before a templated one, so `/pets/mine` gets its own
  Stub and `/pets/7` the pattern's. Two patterns that can match the same
  request keep the document's order.
- `smock import-openapi` puts the path of the server URL in front of every
  path, so the mock answers where the real service does: under the server
  `https://api.example.com/v1`, `/pets/{petId}` becomes the pattern
  `/v1/pets/[^/]+`. The server is the first of the operation's, its Path
  Item's or the document's, with its variables replaced by their
  defaults. Its host is not used. `--base-path` replaces the prefix, to
  mount the API where the system under test calls it, and `--base-path /`
  means none.
- `smock import-openapi` gives every documented response a Stub, not only
  the main one. A request selects it with the header `Smock-Status`,
  whose value is the response key as the document writes it, such as
  `404`, `4XX` or `default`. Without the header, or with a key that no
  Stub names, the main response answers. A test that reaches the Mock
  through its system under test adds an Ephemeral Stub for its Session
  instead, as the guide shows.
- `smock import-openapi` gives responses a body: one fixed sample of the
  schema of one media type, written in the file as `json` or `body`, with
  the media type as the Content-Type. Formats such as `date-time`, `uuid`
  and `email` give valid samples. Nothing is random and nothing is
  templated.
- `smock import-openapi` takes bodies from the document's examples first:
  a media type's `examples`, then its `example`, then a sample of its
  schema. The first named example is the response's body. Every further
  one gets a Stub of its own, which a request selects with the header
  `Smock-Example: <name>`, alone or with `Smock-Status`. An example body
  above 1 MiB is left empty, with a warning.
- `smock import-openapi` samples schemas composed with `allOf`, `oneOf`
  and `anyOf`. `allOf` is merged into one schema, and `oneOf` and `anyOf`
  take their first branch that is not only null, so a nullable field
  written as a `oneOf` with a null branch gets a sample of the other
  branch. `not`, `if`, `then`, `else` and `discriminator` are ignored.
- `smock import-openapi` samples numbers within `minimum`, `maximum` and
  their exclusive forms, so clients that check ranges accept them: 0 when
  the bounds allow it, else the nearest bound, moved inside an exclusive
  one. The arithmetic is exact on the bounds' decimal text, with no float,
  so every platform writes the same digits.
- `smock import-openapi` follows `$ref` in schemas, into other files too.
  In 3.1 and 3.2, the keywords beside a `$ref` are merged with the schema
  it names; in 3.0, they are ignored. A recursive schema gives a finite
  sample: the schema reached again is left out as an optional property,
  gives `[]` as array items, and null otherwise. A sample nests at most 32
  levels. A sample whose compact JSON would pass 64 KiB is made again
  with only its required parts below its first level, and in YAML the
  Stub's comment says `sample cut`; one that would still pass 1 MiB
  leaves the body empty, with a warning. A header's sample has the same
  bounds. A `$id` with a `$ref` under it, and `$dynamicRef`, are errors.
- `smock import-openapi` writes the headers a response documents in the
  Stub's response, with their example, else a sample of their schema, so
  clients that read them see them. A number, a boolean and an array of
  these are written as text, an array joined with `,`. `Content-Type`,
  `Content-Length`, `Transfer-Encoding` and `Connection` are skipped. A
  header smock cannot send, such as one whose value is an object, is left
  out with a warning.
- `smock import-openapi` writes YAML when the name of `--output` ends in
  `.yaml` or `.yml`, and JSON when it ends in `.json`. A YAML file starts
  with a comment that names the document and says not to edit the file,
  and each Stub has a comment that maps it back to the document's
  operation.
- `smock import-openapi` reads YAML documents, whose names end in `.yaml`
  or `.yml`, as YAML 1.2, as OpenAPI recommends. An unquoted status key
  such as `200:` is the key `"200"`, and a date in an example is a string.
  Anchors, aliases and tags stay errors, each at its pointer; the guide
  shows how to convert such a document to JSON first.
- `smock import-openapi` follows a `$ref` where it reads a Path Item, a
  Response, a Header, an Example or, in 3.2, a Media Type: within the document, by
  its JSON Pointer fragment, and into other files by their relative paths.
  Other files are read only under `--ref-dir`, by default the document's
  directory, so a downloaded document cannot copy a secret into a
  committed file; a path or a symlink that leads outside is an error. At
  most 1,000 documents and 64 MiB are read. A URL or an absolute path is
  an error that suggests bundling the document into one file first.
- `smock import-openapi --overwrite on` replaces an earlier output, so a
  changed document reaches the mock when the command runs again. Without
  it, an existing `--output` is refused before the document is read. The
  file is written to a temporary file whose name starts with `.`, then
  renamed, so a smock that watches the directory never loads half a file.
  A directory, a symlink, the document itself or a file it refers to,
  and an `--output` whose directory does not exist are refused. The guide shows how to keep hand
  changes in another file, and how CI can check that the file is current.
- `smock import-openapi --hosts` gives the imported Mock its Hosts, so it
  can share a definitions directory with other Mocks. The document's
  `servers` never become Hosts. A Host that a Definition file could not
  declare, or that repeats, is a usage error. `--declare-mock off` writes
  only Stubs, for a Mock declared by hand in another file, such as to set
  `default`, `noMatch` or `journal`.
- The README documents `smock import-openapi` and its flags. The Mockoon
  migration guide no longer lists OpenAPI import among what smock does not
  do: an environment that Mockoon imported from an OpenAPI document can be
  imported into smock from the same document. The import guide has notes
  for Mockoon users and for Prism users, where `Prefer: code=404` is
  `Smock-Status: 404`, and says how to deploy a large output.
- `write` in the `smock/yaml` module turns a JSON tree into a YAML
  document, with comments, that the module's own parser reads back as the
  same tree. A string is quoted only when it would not read back as the
  same string. The OpenAPI import writes YAML Definition files with it.
- `parse` in the `smock/yaml` module has a mode for OpenAPI documents,
  `openapi=true`. It types plain values by the YAML 1.2 core schema, as
  OpenAPI asks: `200:` is the key `"200"`, `2020-01-01` and `yes` are
  strings, `007` is the number 7, and `~` is null. It also accepts block
  scalar indentation indicators such as `|2`. Definition files keep the
  safe subset, unchanged. The OpenAPI import reads YAML documents with it.

## [0.2.0] - 2026-10-21

### Added

- Operators in request conditions. `$not` negates a condition, and
  `$exists` asks whether a query parameter, header, cookie, form field or
  XML path is present. Inside `json` conditions, `$not` and `$exists` work
  on any value, `$includes` matches an array with an element that meets
  its condition, and `$$name` writes a key that starts with `$`.
- `cookies` conditions match the cookies of the request by name, from
  every `Cookie` field.
- `form` body conditions match the fields of an
  `application/x-www-form-urlencoded` body by name. They hold only when the
  Content-Type says the body is a form.
- `xml` body conditions match the values at simple paths into an XML body,
  such as `/Envelope/Body/GetUser/id` or `/order/item/@sku`. A body that is
  not well-formed XML, or that has a DOCTYPE, fails them.
- The `smock/xml` module, the XML parser and paths behind `xml` conditions.
  It does no I/O and depends only on `moonbitlang/core`.
- The Near miss names the new conditions `cookie:<name>`, `form:<name>` and
  `xml:<path>`, and shows operators as the Stub writes them. Journal
  filters take `$not` and `$exists` for headers.

### Changed

- Two kinds of `json` condition written for smock 0.1 now mean something
  else. The Definition file format is still version 1.
  - An object whose only key is `$not`, `$exists` or `$includes` was
    literal JSON, and is now an operator.
  - A key that starts with `$$`, such as `$$id`, matched that key as
    written, and now matches it with one `$` less, `$id`.

  Any other key that starts with `$` in a `json` condition is now an
  error, so a file with one fails to load rather than change its meaning:
  write the key with `$$`.
- The Journal bounds the form and XML values that an entry's Near miss
  keeps. They are kept in order until their total reaches
  `--journal-body-limit`, each counting its bytes and 32 bytes more; the
  last one kept is cut, and the rest are dropped. The 32 bytes per value
  also count toward `--journal-max-bytes`.

## [0.1.0] - 2026-10-19

- The first public release.

[Unreleased]: https://github.com/hirunefu/smock/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hirunefu/smock/releases/tag/v0.2.0
[0.1.0]: https://github.com/hirunefu/smock/releases/tag/v0.1.0
