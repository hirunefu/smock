# Importing OpenAPI

`smock import-openapi` converts an OpenAPI 3.0, 3.1 or 3.2 document into
one Definition file, once. The file is committed and reviewed like any
other, and smock serves it like any other. smock never reads OpenAPI when
it serves: the Definition files stay the only source of truth
([ADR 0002](adr/0002-definition-files-are-the-source-of-truth.md)). When
the document changes, run the command again and review the diff.

The command is new, and it imports part of a document so far. What it
does not import yet is left out with a warning, so nothing is dropped
without a word. [Limits](#limits) lists those parts.

## Quick start

Take a document whose only operation is `listPets` on `GET /pets`:

```json
{
  "openapi": "3.1.0",
  "info": { "title": "Petstore", "version": "1.0.0" },
  "paths": {
    "/pets": {
      "get": {
        "operationId": "listPets",
        "responses": { "200": { "description": "A list of pets" } }
      }
    }
  }
}
```

Import it into the definitions directory, then check the directory:

```sh
smock import-openapi api/petstore.json --mock petstore --output definitions/petstore.json
smock check definitions
```

The command prints one line:

```
wrote definitions/petstore.json: 1 Stubs from 1 operations, 0 warnings
```

It writes this file:

```json
{
  "version": 1,
  "mocks": [
    {
      "name": "petstore"
    }
  ],
  "stubs": [
    {
      "id": "petstore.listPets.200",
      "mock": "petstore",
      "request": {
        "method": "GET",
        "path": "/pets"
      },
      "response": {
        "status": 200
      }
    }
  ]
}
```

`smock serve --dir definitions` then answers `GET /pets` with 200, and
the Journal names the Stub `petstore.listPets.200`.

The arguments:

- `<document>`: the OpenAPI document, a file whose name ends in `.json`.
  It is not a URL, and not stdin.
- `--mock <name>`: the name of the one Mock the file declares. Every Stub
  ID starts with it, and it names the Mock in metric labels and Admin API
  paths. It is not taken from the document's title, which changes between
  versions.
- `--output <file>`: the Definition file to write, whose name ends in
  `.json`. It must not exist: the command creates the file new, and never
  replaces one. A name that starts with `.` is refused, since smock skips
  such files.

The flags belong to one run, so none has an `SMOCK_` variable.

## Validate the document first

The command is not a validator. It reads the parts it imports, and an
error there stops it, but a mistake in a part it does not read, such as a
request body, does not. Check the document with a validator first, such
as [openapi-spec-validator](https://github.com/python-openapi/openapi-spec-validator),
which smock's own CI runs on the Admin API's document:

```sh
uvx --from openapi-spec-validator==0.9.0 openapi-spec-validator api/petstore.json
```

## What is generated

The file declares one Mock, named by `--mock`, with no other field. Then
come the Stubs, one per operation, in the order the document writes the
operations: path keys, then methods in the order each Path Item writes
them.

| In the document | In the Definition file |
|---|---|
| The document | `version: 1`, then `mocks` with the one Mock, then `stubs`. |
| An operation | One Stub, the operation's main Stub. |
| `get`, `put`, `post`, `delete`, `options`, `head`, `patch`, `trace`, and 3.2's `query` | The `method`, in upper case. |
| A key of 3.2's `additionalOperations` | The `method`, as written. |
| `head` | `HEAD` is answered only where the document has `head`. |
| A path key without parameters | The exact `path`, percent-decoded as smock decodes request paths, so that the match index finds it. |
| `operationId` | The Stub ID `<mock>.<operationId>.<key>`, where `<key>` is the main response's key, such as `petstore.listPets.200`. |
| No `operationId` | The Stub ID `<mock>.<METHOD> <path>.<key>`, with the path as written, such as `petstore.GET /pets.200`. |
| The main response | The `status` (see below). |
| Parameters, request bodies, `Content-Type`, `Accept` and `security` | No condition, so a request without a documented parameter still gets the documented answer. |
| `deprecated: true` | Nothing: the operation is imported like any other. |
| `callbacks` | Not imported, with one warning per operation. |
| `webhooks` | Not imported, with one warning: they are requests the API sends, not ones it answers. |
| `security`, `links`, descriptions, tags and `x-` extensions | Nothing, and no warning. |

A Stub matches on its method and its path only. The file holds only
`status`, `headers`, and `json` or `body` in its responses: no
`template`, `responses`, `variables`, `fault`, `scenario` or `priority`.

### The main response

Each operation answers one main response. It is the first of these that
the operation's `responses` has:

1. the lowest explicit code from 200 to 299, then `2XX`;
2. `default`, which answers 200;
3. the lowest explicit code from 300 to 599, then `3XX`, `4XX` and `5XX`.

An explicit code answers itself, and a range answers its first code: 200,
300, 400 or 500.

- An operation without `responses`, or with an empty one, answers 200
  with an empty body, with a warning. Its Stub ID ends in `.200`.
- An operation with only 1xx responses is left out, with a warning: smock
  answers with a status from 200 to 599.
- A response key that is not a code from 100 to 599, a range from `1XX`
  to `5XX` in upper case, `default` or an `x-` extension is left out,
  with a warning. `x-` keys are ignored.

### IDs and conditions that repeat

- Two imported operations with the same `operationId` are an error that
  names both places. So is any generated Stub ID that repeats.
- When two operations' method and path come out the same, the first in
  document order is kept, and the later one is left out with a warning.
  Two paths that decode alike, such as `/a%2Fb` and `/a/b`, are the same
  path.
- Operations that are left out take part in neither check.

## Problems and exit codes

Each problem is one line on stdout, in the form `smock check` uses:

```
api/petstore.json: /paths/~1pets/get/responses/404: warning: left out: only the main response, 200, is imported yet
```

- The document is named as given on the command line, and the place is
  an [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) JSON Pointer to
  where the construct is written. In a pointer, `/` in a key is written
  `~1`, so `/paths/~1pets` is the path key `/pets`.
- Errors have no `warning:`. An error is what makes a faithful file
  impossible, such as invalid JSON, an unsupported version, a malformed
  path, a field of the wrong type or IDs that collide. A warning names a
  part of the document that was left out; the file still serves the rest.
- Problems with `--output` come first, named by `--output` as given. Then
  the document-level ones. Then each operation's, in the order the
  document writes the operations, and within an operation in the order of
  its responses.
- One summary line ends the output: `wrote <file>: <n> Stubs from <m>
  operations, <w> warnings`, or `nothing written: <e> errors`.

| Exit status | Meaning |
|---|---|
| 0 | The file was written, with or without warnings. |
| 1 | Nothing was written: the document or the output had an error. |
| 2 | A usage error, such as a missing flag, printed on stderr. |

The input must be UTF-8 JSON. A leading byte order mark is skipped. A key
that repeats in an object is an error at its pointer, as in a Definition
file. `openapi` must be a string `3.<minor>.<patch>`, such as `"3.1.0"`,
for 3.0, 3.1 or 3.2; the patch is ignored. A Swagger 2.0 document is an
error: convert it to OpenAPI 3.0 first.

Before it writes, the command loads its own output with the loader
`smock check` uses. The output must be valid and give no warning. If not,
nothing is written, and the message calls it a smock bug: please report
it.

The same document and flags always give the same bytes, on every
platform, so a generated file changes only when the document or the
command does.

## Limits

- The file is at most 64 MiB. A larger output is an error that gives its
  size, and nothing is written.
- These parts are not imported yet. Each is left out with a warning,
  unless this list says otherwise:
  - operations at paths with parameters, such as `/pets/{petId}`;
  - the paths of `servers`, so no prefix is added to the paths;
  - responses other than the main one;
  - response bodies and response headers;
  - references: a `$ref` where the command reads a Path Item or a
    Response is an error, so write the part it names in its place;
  - YAML: a `.yaml` or `.yml` document or output is a usage error;
  - replacing an earlier output: an existing `--output` is refused before
    the document is read, and nothing is written.
