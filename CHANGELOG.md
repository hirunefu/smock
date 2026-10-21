# Changelog

All notable changes to smock are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The notes
of each GitHub release include its section
([docs/releasing.md](docs/releasing.md#every-release-after)).

## [Unreleased]

### Added

- `cookie.NAME` in templates reads a cookie as cookie conditions read it,
  from every `Cookie` field, with quotes kept and nothing percent-decoded.
  It is the first value of the cookie, and `$each` over it walks every
  value.
- Template helpers for text: `len`, `concat`, `padStart`, `padEnd`,
  `substr`, `indexOf`, `includes`, `replace`, `replaceAll`, `split` and
  `join`. Lengths and positions count Unicode code points. A text argument
  may be a number or a boolean, taken as its text. `replace` and
  `replaceAll` take the replacement literally. `split` gives an array that
  `$each` can walk, and `join` turns an array back into text.
- Template helpers `uppercase`, `lowercase` and `trim`, from the data of
  Unicode 18.0.0, built in: simple case mapping, one code point to one and
  with no locale (`ß` stays `ß`), and White_Space removed at both ends.
- A helper call can be followed by steps, as a reference can:
  `${range(1, 3)[1]}` gives `2`.
- The bounds of `range(a, b)` can be any expression that gives an integer,
  such as `len(body.items)`.
- A helper's result above 1 MiB is a render error, found before the
  result is built.
- `--template-env` (`SMOCK_TEMPLATE_ENV`) on `smock serve`, `smock check`
  and `smock render` lists, separated by commas, the environment variables
  templates may read. Their values are read once, at startup, and every
  load, reload and Ephemeral Stub uses them. A name that starts with
  `SMOCK_` cannot be listed.
- The template root `env.NAME` gives the value of a listed variable as a
  string, and is missing when it is unset. A name that is not listed is an
  error when loading.
- `responses`: a Stub can give 1 to 100 responses with integer weights,
  from 1 to 1,000,000, instead of `response`. Each matched request gets
  one of them, picked with the probability of its weight over the sum of
  the weights, so the status can vary. The pick draws from the request's
  one random draw, so `fault.seed` and `--seed` replay it, and it leaves a
  seed's Fault decisions and helper output as they are. Ephemeral Stubs
  take `responses` with inline bodies.
- Journal entries record `responseIndex`, the index of the response a
  request got, or null for a Stub with `response` and for a request no
  Stub matched.
- `smock render` and the Admin render operation show `responseIndex`, and
  render a given response with `--response <i>` and the `response` query
  parameter.
- Variables: named JSON values kept per Mock and Session. A Stub's
  `variables` write them when it matches, before its response is built,
  and templates read them as `vars.NAME`, so a POST can store what a later
  GET returns. Each value is a template, rendered against the Variables as
  they were before the request; a value that fails to render writes none
  of them. Ephemeral Stubs take `variables` too.
- Journal entries record `variablesWritten`, the names of the Variables a
  request wrote.

### Changed

- A loop variable named `cookie`, `env` or `vars` now fails to load, since
  `cookie`, `env` and `vars` are template roots. No valid file changes
  meaning: rename the loop variable. The Definition file format is still
  version 1.

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
