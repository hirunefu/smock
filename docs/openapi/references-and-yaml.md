# References, bundling and YAML

This part of [Importing OpenAPI](../importing-openapi.md) says how
`smock import-openapi`, "the command", reads the OpenAPI document it is
given, "the document": which `$ref` references it follows, when a document
must be bundled into one file first, and how it reads YAML. The command's
arguments are in the guide's [Quick
start](../importing-openapi.md#quick-start), and the problems it prints, and
what the input must be, in [Problems and exit
codes](../importing-openapi.md#problems-and-exit-codes).

## Contents

- [References and bundling](#references-and-bundling)
  - [References to other files](#references-to-other-files)
  - [Bundling](#bundling)
- [How YAML is read](#how-yaml-is-read)

## References and bundling

Documents describe shared parts once, under `components`, and point at
them with `$ref`. The command follows a reference where it reads a Path
Item, a Response, a Header, an Example, a Schema or, as 3.2 allows, a
Media Type, within the document or into another file
([References to other files](#references-to-other-files)):

```json
{
  "openapi": "3.1.0",
  "paths": {
    "/pets": { "$ref": "#/components/pathItems/Pets" }
  },
  "components": {
    "pathItems": {
      "Pets": {
        "get": {
          "operationId": "listPets",
          "responses": { "200": { "$ref": "#/components/responses/Ok" } }
        }
      }
    },
    "responses": {
      "Ok": { "description": "OK" }
    }
  }
}
```

This imports `listPets` as if both parts were written in place.

- A reference names a part of the same document by its fragment, an
  [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) JSON Pointer such as
  `#/components/responses/Ok`. The fragment is percent-decoded, `~1` in it
  is `/` and `~0` is `~`, and it may step into arrays, as `#/x-list/0`.
- A reference to a part that is itself a reference is followed on.
- A problem in a part a reference names is reported where that part is
  written, such as `/components/responses/Ok/content`, and only once,
  however many references name it.
- Operations reached through a Path Item's `$ref` keep the order of the
  path keys.
- The fields beside a Path Item's `$ref` are ignored, with a warning, but
  `x-` extensions. The fields beside the `$ref` of a Response, a Header
  or an Example are ignored, as OpenAPI asks.
- A media type is a reference only from OpenAPI 3.2. In 3.0 and 3.1 a
  `$ref` in a media type is ignored, with a warning, and the rest of the
  media type is read as written. A common slip is a `$ref` to a schema
  written in place of the media type's `schema`.
- A `$ref` inside example data, in `example`, `value` or `dataValue`, is
  data, not a reference: it is copied as written.
- `$id` at the root of the document, and 3.2's `$self`, are ignored: a
  reference names a part by its fragment.
- A schema may name itself through `$ref`, directly or through others
  ([Schema references and
  recursion](what-is-generated.md#schema-references-and-recursion)).
- References in the parts the command does not read are not followed, so
  a broken one there is no error. These parts are request bodies,
  parameters, `security`, `callbacks`, `webhooks`, `links`, 1xx
  responses, and components that no imported operation reaches.

Each of these is an error at the `$ref`:

- a `$ref` that is not a string;
- a reference to a part the document does not have;
- a fragment that is not a JSON Pointer, such as an `$anchor` name like
  `#Pet`;
- references that form a cycle, within a document or across files,
  unless it passes through a Schema;
- a URL, of any scheme, `file:` included, or an absolute path. smock
  reads no URLs;
- a reference to a file outside `--ref-dir`, to a file whose name does not
  end in `.json`, `.yaml` or `.yml`, or to a file that cannot be read.

In a schema, a `$id` inside a document is an error, at the `$id`, when
a `$ref` lies under it or beside it. `$dynamicRef` is an error too.

### References to other files

A document split into several files can be imported. Here
`api/openapi.yaml` names a response in another file:

```yaml
openapi: 3.1.0
paths:
  /pets:
    get:
      operationId: listPets
      responses:
        "200":
          $ref: "responses/ok.yaml#/Ok"
```

```sh
smock import-openapi api/openapi.yaml --mock petstore --output defs/petstore.yaml
```

The command reads `api/responses/ok.yaml` and follows the reference to its
`Ok` member.

- A reference to another file is a relative path, then an optional
  fragment. The path is percent-decoded, so `my%20responses/ok.yaml` names
  `my responses/ok.yaml`. It must end in `.json`, `.yaml` or `.yml`.
- The path is resolved against the directory of the document that names
  it. So a reference in `api/paths/pets.yaml` to `../responses/ok.yaml`
  names `api/responses/ok.yaml`.
- The file is read as the document is, by its extension: YAML 1.2 or
  JSON. It need not be an OpenAPI document, so a JSON Schema file will
  do. Its `openapi` field, if any, is not checked. The schema rules follow
  the version of the document given on the command line.
- Each file is read once, however many references name it. A reference
  in it may name another file, or a part of the document itself.

Files are read only under one directory, `--ref-dir`. By default it is
the document's own directory, and the document must lie under it. A
reference that leads outside it is an error, so a downloaded document
cannot copy a secret such as `../../.npmrc` into a committed file:

- a path that climbs above `--ref-dir`, such as `../shared/errors.yaml`
  from a document at the top of it;
- a file that a symlink leads outside `--ref-dir`, as for body files:
  the file itself is the symlink, or a directory on its path is. A
  symlink that stays inside is followed.

When the parts a document shares sit in a directory beside it, give a
`--ref-dir` that holds both:

```sh
smock import-openapi api/openapi.yaml --mock petstore --ref-dir . --output defs/petstore.yaml
```

A document outside `--ref-dir`, or a `--ref-dir` that is not a directory,
is a usage error, with exit status 2.

A problem in another file names it as `--ref-dir`, as given, joined with
its path under `--ref-dir`, such as `./api/responses/ok.yaml` above.
Without `--ref-dir`, the directory part of the document's path, as given,
takes its place: `api/responses/ok.yaml`. A file that cannot be read is
an error at each `$ref` that names it, with [the document-level
problems](../importing-openapi.md#problems-and-exit-codes):

```
api/openapi.yaml: /paths/~1pets/get/responses/200/$ref: api/responses/ok.yaml cannot be read: no such file
```

The reasons are `no such file`, `not a regular file`, `a symlink leads it
outside --ref-dir`, or the system's own, such as `permission denied`. A
file that is not valid YAML or JSON is an error in it, once.

No path reaches the generated file, so the same documents give the same
bytes whatever `--ref-dir` and the paths given.

### Bundling

A document whose references name URLs, or more files than smock reads (see
[Limits](../importing-openapi.md#limits)), must be bundled into one file
first, with another tool. A bundler copies what the references name into
`components`, and points at it with references within the document. For
example, with [Redocly CLI](https://redocly.com/docs/cli/):

```sh
npx @redocly/cli@2.55.0 bundle api/petstore.json --output api/petstore.bundled.json
smock import-openapi api/petstore.bundled.json --mock petstore --output defs/petstore.json
```

A bundler fetches what the URLs name. smock never does.

## How YAML is read

A document whose name ends in `.yaml` or `.yml` is read as YAML 1.2, the
YAML version OpenAPI recommends. One whose name ends in `.json` is read as
JSON. A JSON document may start with one byte order mark (U+FEFF), which
is dropped; a second is an error that starts with "not valid JSON", as
any other text outside JSON's syntax is. Definition files are not read
this way: they keep the safe subset of YAML that the [Definition-file
reference](../definition-files.md#writing-definition-files-in-yaml)
describes, and the command writes its YAML output in that subset.

Values without quotes are typed by the YAML 1.2 core schema:

| Plain value | Read as |
|---|---|
| `null`, `Null`, `NULL`, `~`, or no value at all | null |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | a boolean |
| `007`, `+1`, `.5`, `0x1F`, `0o17` | a number: 7, 1, 0.5, 31 and 15 |
| `yes`, `no`, `on`, `off`, `2020-01-01`, `1_000` | a string |

Points with no digit, with or without a sign before them and an exponent
after them, such as `.`, `..`, `+.` or `.e3`, are strings too: a number of
the core schema has a digit.

Every key is a string, as OpenAPI asks, so an unquoted `200:` is the
response key `"200"`. This document imports as if it were written in JSON
with the key `"200"`:

```yaml
openapi: 3.1.0
paths:
  /pets:
    get:
      responses:
        200:
          description:
          content:
            application/json:
              schema:
                properties:
                  born: { example: 2020-01-01 }
                  code: { example: 007 }
                  tag: { example: ~ }
```

Its body is `{"born": "2020-01-01", "code": 7, "tag": null}`.

- A decimal integer keeps all its digits, as in JSON, even past 2^53.
- Block scalars may have an indentation indicator, as in `|2` or `>-1`.
  YAML writers emit one for text that starts with spaces, such as an
  indented code sample in a `description`.
- `openapi: 3.1` without quotes is the number 3.1, which is an error:
  quote the version and give its patch, as in `openapi: "3.1.0"`. An
  unquoted `3.1.0` is already a string. An unquoted `version: 1.0` under
  `info` is a number too. It is left out of [the comment at the
  top](../importing-openapi.md#quick-start), with a warning that says to
  quote it.

The YAML parser also holds to these rules:

- A key with nothing written, as in `: value`, is an error, "a key must
  not be empty", though an empty value is null: every key is a string.
- A plain value that JSON cannot hold, such as `.inf`, `.NaN` or a
  hexadecimal or octal integer above 2^53 - 1, is an error whose message
  ends in "quote this value". Quoted, it is a string.
- The members of a mapping are read in the order they are written.
- A `#` starts a comment only at the start of a line or after a space or
  a tab, as YAML says. Right after other text of a plain value, it is part
  of the value, as in `url: /pets#top`; anywhere else, such as right after
  a quoted value or a flow collection, as in `type: "string"# note`, it is
  an error, "a comment needs a space before its #".
- A byte order mark (U+FEFF) may start the file, and is dropped there:
  one, and no more. Anywhere else, it is text inside a quoted value, as
  YAML says, and an error outside quotes. A second mark at the start of
  the file, and a mark in a plain value or key, a comment or a block
  scalar's content, are an error, "U+FEFF is a byte order mark; write it
  as an escape in a double-quoted value". Elsewhere, as right after a
  quoted value or a flow collection, or in a block scalar's header, the
  error is the one that place gives any other character.
- A block scalar whose last line ends the file without a line break gets
  no line break added, as YAML 1.2.2 says (section 8.1.1.2), with each
  chomping indicator: a file that ends with `description: |` and then
  `  A pet`, with no line break after it, reads `description` as
  `"A pet"`.

Each of these is an error at its pointer, with a message that names it,
and nothing is written:

- anchors (`&`), aliases (`*`) and merge keys (`<<`);
- tags, such as `!!str`;
- a key that repeats in a mapping, such as `200:` and `"200":`;
- more than one document, directives such as `%YAML 1.2`, and explicit
  keys (`?`);
- a hexadecimal or octal integer above 2^53 - 1: write it in decimal;
- infinity and NaN, such as `.inf`, `-.Inf` and `.NaN`, which JSON
  cannot hold;
- tabs in indentation, which includes the white space between a `-` and
  a mapping or a sequence that starts on its line, and text that is not
  UTF-8.

For example:

```
api/petstore.yaml: /paths/~1pets/get/responses/200: anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
```

A document that reuses parts with anchors and aliases can use `$ref`
instead, which OpenAPI has for that. Or convert it to JSON with another
tool first. A bundler such as [Redocly CLI](https://redocly.com/docs/cli/)
reads the aliases and writes each part in full:

```sh
npx @redocly/cli@2.55.0 bundle api/petstore.yaml --output api/petstore.bundled.json
smock import-openapi api/petstore.bundled.json --mock petstore --output defs/petstore.yaml
```

Some valid YAML is an error too, on purpose, as it is in Definition files
([Writing Definition files in
YAML](../definition-files.md#writing-definition-files-in-yaml)): a file
with no document, a key that is a collection, a `key: value` pair in a
flow sequence without braces, a key of a flow mapping written over
several lines, a tab in the white space at the start of a line, even
where YAML would read it as a separator rather than as indentation, and
a line of white space whose tab comes before a block scalar's
indentation, with nothing after it but empty lines, comments and the
`...` that may end the document. YAML reads that line as a comment after
the document; smock gives the error for a tab in indentation, as libyaml
and PyYAML do.
