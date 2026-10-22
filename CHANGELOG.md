# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- `smock import-openapi <document> --mock <name> --output <file>` converts
  an OpenAPI 3.0, 3.1 or 3.2 document into one Definition file, once.
  smock never reads OpenAPI when it serves. `--hosts` gives the Mock its
  Hosts, and `--declare-mock off` writes only Stubs, for a Mock declared by
  hand in another file; the document's `servers` never become Hosts. Parts
  that it does not import, such as callbacks and webhooks, are left out
  with a warning. See [docs/importing-openapi.md](docs/importing-openapi.md).
  The Mockoon migration guide points there too: an environment that
  Mockoon imported from an OpenAPI document can be imported into smock from
  the same document.
- Each imported operation, 3.2's `query` and `additionalOperations`
  included, becomes Stubs that match its method and its path, under the
  path of its server URL, so the mock answers where the real service does;
  `--base-path` replaces that prefix. A path with parameters, such as
  `/pets/{petId}`, becomes a pattern in which each parameter matches one
  segment, and concrete paths come before templated ones. The main
  response answers by default. Every other response has a Stub that a
  request selects with `Smock-Status: <key>`, such as `404`, and every
  further named example one that `Smock-Example: <name>` selects. A test
  that reaches the mock through its system under test adds an Ephemeral Stub
  for its Session instead, as the guide shows.
- Imported bodies come from a media type's `examples`, then its `example`,
  then one fixed sample of its schema, written in the file as `json` or
  `body`, with the media type as the Content-Type. Samples follow formats,
  number bounds, `allOf`, `oneOf` and `anyOf`, and `$ref`, recursive schemas
  included. Nothing is random and nothing is templated, and number bounds
  use exact decimal arithmetic on the shortest decimal text of each bound,
  so every platform writes the same digits. A sample nests at most 32
  levels, one above 64 KiB is cut to its required parts, and a body above
  1 MiB is left empty, with a warning.
  The headers a response documents are written too, with their example or a
  sample of their schema; a header with neither is left out, with a
  warning.
- `smock import-openapi` reads YAML documents as YAML 1.2, as OpenAPI
  recommends, so `200:` is the key `"200"` and a date is a string; anchors
  and aliases stay errors. It follows a `$ref` where OpenAPI allows one,
  within the document and into other files under `--ref-dir`, by default the
  document's directory, so a downloaded document cannot copy a secret into a
  committed file. At most 1,000 documents and 64 MiB are read. A URL is an
  error that suggests bundling the document into one file first.
- The import writes YAML or JSON, as the name of `--output` says. A YAML
  file starts with a comment that names the document and the flags whose
  value is not the default, and says not to edit the file, and each Stub
  has one that maps it back to its operation. An existing file is replaced
  only with `--overwrite on`, through a temporary file and a rename, so a
  smock that watches the directory never loads half a file. The guide shows how to keep hand changes in another file, and how
  CI can check that the file is current.
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
