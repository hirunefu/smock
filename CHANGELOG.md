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
  that are not imported yet are left out with a warning. smock never reads
  OpenAPI when it serves. See
  [docs/importing-openapi.md](docs/importing-openapi.md).
- `smock import-openapi` turns a path with parameters, such as
  `/pets/{petId}`, into a pattern in which each parameter matches text
  within one segment, and keeps a path without parameters exact. A
  concrete path comes before a templated one, so `/pets/mine` gets its own
  Stub and `/pets/7` the pattern's. Two patterns that can match the same
  request keep the document's order.
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
  templated. Numbers sample as 0 so far, and `allOf`, `oneOf`, `anyOf`,
  schema references and the document's examples are not used yet.
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
- `smock import-openapi` follows a `$ref` within the document where it
  reads a Path Item, a Response or a Media Type, by its JSON Pointer
  fragment. A URL, an
  absolute path or another file is an error that suggests bundling the
  document into one file first.
- `smock import-openapi --overwrite on` replaces an earlier output, so a
  changed document reaches the mock when the command runs again. Without
  it, an existing `--output` is refused before the document is read. The
  file is written to a temporary file whose name starts with `.`, then
  renamed, so a smock that watches the directory never loads half a file.
  A directory, a symlink, the document itself and an `--output` whose
  directory does not exist are refused. The guide shows how to keep hand
  changes in another file, and how CI can check that the file is current.
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
