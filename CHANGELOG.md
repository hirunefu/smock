# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- `smock import-openapi` converts a JSON OpenAPI 3.0, 3.1 or 3.2 document
  into a Definition file, once. Each operation at a path without
  parameters becomes a Stub that matches its method and exact path and
  answers its main status. Parts that are not imported yet are left out
  with a warning. smock never reads OpenAPI when it serves. See
  [docs/importing-openapi.md](docs/importing-openapi.md).
- `smock import-openapi` writes YAML when the name of `--output` ends in
  `.yaml` or `.yml`, and JSON when it ends in `.json`. A YAML file starts
  with a comment that names the document and says not to edit the file,
  and each Stub has a comment that maps it back to the document's
  operation.
- `write` in the `smock/yaml` module turns a JSON tree into a YAML
  document, with comments, that the module's own parser reads back as the
  same tree. A string is quoted only when it would not read back as the
  same string. The OpenAPI import writes YAML Definition files with it.
- `parse` in the `smock/yaml` module has a mode for OpenAPI documents,
  `openapi=true`. It types plain values by the YAML 1.2 core schema, as
  OpenAPI asks: `200:` is the key `"200"`, `2020-01-01` and `yes` are
  strings, `007` is the number 7, and `~` is null. It also accepts block
  scalar indentation indicators such as `|2`. Definition files keep the
  safe subset, unchanged. The OpenAPI import will read YAML documents with
  it.

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
