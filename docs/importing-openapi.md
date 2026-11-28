# Importing OpenAPI

`smock import-openapi` converts an OpenAPI 3.0, 3.1 or 3.2 document into
one Definition file, once. The file is committed and reviewed like any
other, and smock serves it like any other. smock never reads OpenAPI when
it serves: the Definition files stay the only source of truth
([ADR 0002](adr/0002-definition-files-are-the-source-of-truth.md)). When
the document changes, run the command again with `--overwrite on` and
review the diff ([Regenerating](#regenerating)). The command came in
smock 0.3.0.

A part of the document that the command does not import, such as
`callbacks`, is left out with a warning. [What is
generated](openapi/what-is-generated.md), a page of its own in
`docs/openapi/`, says what becomes of each part, and [Limits](#limits) gives
the bounds the command keeps to. The guide's other page there,
[References, bundling and YAML](openapi/references-and-yaml.md), says which
references the command follows, when a document must be bundled first, and
how YAML is read.

## Contents

On this page:

- [Quick start](#quick-start)
- [Validate the document first](#validate-the-document-first)
- [The Mock and its Hosts](#the-mock-and-its-hosts)
- [Selecting responses](#selecting-responses)
  - [Selecting examples](#selecting-examples)
  - [Through the system under test](#through-the-system-under-test)
- [Regenerating](#regenerating)
  - [Overrides](#overrides)
  - [Checking that the file is current](#checking-that-the-file-is-current)
- [Problems and exit codes](#problems-and-exit-codes)
- [Notes for Mockoon users](#notes-for-mockoon-users)
- [Notes for Prism users](#notes-for-prism-users)
- [Limits](#limits)

On the guide's other pages:

- [What is generated](openapi/what-is-generated.md)
  - [Paths with parameters](openapi/what-is-generated.md#paths-with-parameters)
  - [Servers and base paths](openapi/what-is-generated.md#servers-and-base-paths)
  - [The main response](openapi/what-is-generated.md#the-main-response)
  - [The other responses](openapi/what-is-generated.md#the-other-responses)
  - [Bodies](openapi/what-is-generated.md#bodies)
  - [Bodies from examples](openapi/what-is-generated.md#bodies-from-examples)
  - [Samples from schemas](openapi/what-is-generated.md#samples-from-schemas)
  - [Response headers](openapi/what-is-generated.md#response-headers)
  - [IDs and conditions that repeat](openapi/what-is-generated.md#ids-and-conditions-that-repeat)
- [References, bundling and YAML](openapi/references-and-yaml.md)
  - [References and bundling](openapi/references-and-yaml.md#references-and-bundling)
  - [How YAML is read](openapi/references-and-yaml.md#how-yaml-is-read)

## Quick start

The example is in [`examples/from-openapi/`](examples/from-openapi/): the
OpenAPI document `api/petstore.yaml`, and the definitions directory
`defs/`, which holds the file that the command writes from it. The
commands below run in `docs/examples/from-openapi/`. `smock check` passes
on the directory, and smock gives the answers this section shows.

The document has two operations under the server path `/v1`: `listPets`
on `GET /pets`, whose schema has no example, and `getPet` on
`GET /pets/{petId}`, with the named examples `cat` and `dog`, and a 404:

```yaml
openapi: 3.1.0
info:
  title: Petstore
  version: 1.0.0
servers:
  - url: https://petstore.example.com/v1
paths:
  /pets:
    get:
      operationId: listPets
      summary: List all pets
      responses:
        "200":
          description: A list of pets
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: "#/components/schemas/Pet"
  /pets/{petId}:
    get:
      operationId: getPet
      summary: Show one pet
      parameters:
        - name: petId
          in: path
          required: true
          schema:
            type: integer
      responses:
        "200":
          description: The pet
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Pet"
              examples:
                cat:
                  value:
                    id: 7
                    name: Tom
                    species: cat
                dog:
                  value:
                    id: 7
                    name: Rex
                    species: dog
        "404":
          description: No pet has this ID
          content:
            application/json:
              example:
                message: Pet not found
components:
  schemas:
    Pet:
      type: object
      required: [id, name]
      properties:
        id:
          type: integer
        name:
          type: string
        species:
          type: string
          enum: [cat, dog]
```

Import it into the definitions directory, then check the directory:

```sh
smock import-openapi api/petstore.yaml --mock petstore --output defs/petstore.yaml
smock check defs
```

The command prints one line:

```
wrote defs/petstore.yaml: 4 Stubs from 2 operations, 0 warnings
```

It writes this file:

```yaml
# Generated by smock import-openapi from petstore.yaml
# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
# Do not edit: the next import replaces this file.
version: 1
mocks:
  - name: petstore
stubs:
  # GET /pets, 200: List all pets
  - id: petstore.listPets.200
    mock: petstore
    request:
      method: GET
      path: /v1/pets
    response:
      status: 200
      json:
        - id: 0
          name: string
          species: cat
  # GET /pets/{petId}, 404: Show one pet
  - id: petstore.getPet.404
    mock: petstore
    request:
      method: GET
      path:
        pattern: /v1/pets/[^/]+
      headers:
        Smock-Status: "404"
    response:
      status: 404
      json:
        message: Pet not found
  # GET /pets/{petId}, 200, example dog: Show one pet
  - id: petstore.getPet.200.dog
    mock: petstore
    request:
      method: GET
      path:
        pattern: /v1/pets/[^/]+
      headers:
        Smock-Example: dog
    response:
      status: 200
      json:
        id: 7
        name: Rex
        species: dog
  # GET /pets/{petId}, 200, example cat: Show one pet
  - id: petstore.getPet.200
    mock: petstore
    request:
      method: GET
      path:
        pattern: /v1/pets/[^/]+
    response:
      status: 200
      json:
        id: 7
        name: Tom
        species: cat
```

`smock serve --dir defs` then answers:

```sh
curl localhost:8080/v1/pets                            # 200, a sample of the schema
curl localhost:8080/v1/pets/7                          # 200, the first example: Tom
curl -H "Smock-Example: dog" localhost:8080/v1/pets/7  # 200, the example dog: Rex
curl -H "Smock-Status: 404" localhost:8080/v1/pets/7   # 404, Pet not found
curl localhost:8080/pets/7                             # 404: no Stub matches
```

- The path of the server, `/v1`, comes before every path ([Servers and base
  paths](openapi/what-is-generated.md#servers-and-base-paths)).
- `/pets` stays an exact path, and `/pets/{petId}` becomes a pattern, so
  every pet ID gets the same answers ([Paths with
  parameters](openapi/what-is-generated.md#paths-with-parameters)).
- A body is the first example the document gives, else a sample of the
  schema ([Bodies](openapi/what-is-generated.md#bodies)). `listPets` has no
  example, so its body is a sample: 0 for an integer, `string` for a string,
  and the first value of an `enum` ([Samples from
  schemas](openapi/what-is-generated.md#samples-from-schemas)).
- Each operation answers its main response, here its 200, by default. A
  request selects another response with `Smock-Status`, and a further
  named example with `Smock-Example`
  ([Selecting responses](#selecting-responses)).
- The Journal names the Stub that answered, such as
  `petstore.getPet.200.dog`.

The comments are there for the reader:

- The comment at the top says where the file came from: the document,
  by its base name, with its `info.title`, its `info.version` and its
  OpenAPI version, and the flags that shape the file whose value is not
  the default, so that typing a default changes no byte. It says not to
  edit the file, since the next import replaces it. Put hand changes in
  another file ([Overrides](#overrides)). An `info` that is not an object,
  or a `title` or `version` that is not a string, is left out of the
  comment, with a warning, and the import goes on.
- The comment above each Stub maps it back to the document: the method, the
  path as the document writes it, the response key, the name of the example
  its body comes from, if any, `sample cut` when its body is a sample cut to
  its required parts ([Sample
  size](openapi/what-is-generated.md#sample-size)), `deprecated` when the
  operation is, and the first line of the operation's `summary`.
- The comments hold no path and no smock version. So the same import gives
  the same bytes from any directory, and after an upgrade that does not
  change the conversion. No home directory reaches a committed file
  either.

The arguments:

- `<document>`: the OpenAPI document, a file whose name ends in `.json`,
  `.yaml` or `.yml`. A YAML document is read as YAML 1.2 (see [How YAML is
  read](openapi/references-and-yaml.md#how-yaml-is-read)). It is not stdin,
  and not a URL: download the document first. A URL that cannot be read as a
  file gets that advice too.
- `--mock <name>`: the name of the one Mock the file declares. Every Stub
  ID starts with it, and it names the Mock in metric labels and Admin API
  paths. It is not taken from the document's title, which changes between
  versions.
- `--hosts <h1,h2>`: the Mock's Hosts, separated by commas, such as
  `petstore.test,pets.internal:8080`. None by default. With
  `--declare-mock on`, an empty `--hosts ""` gives none too, as leaving it
  out does. The document's `servers` never become Hosts
  ([The Mock and its Hosts](#the-mock-and-its-hosts)).
- `--declare-mock on|off`: whether the file declares the Mock. It is `on`
  by default. With `off`, the file holds only Stubs, for a Mock declared
  by hand in another file.
- `--ref-dir <dir>`: the directory that references to other files are
  followed in. It is the document's own directory by default, and the
  document must lie under it ([References to other
  files](openapi/references-and-yaml.md#references-to-other-files)).
- `--output <file>`: the Definition file to write. Its name picks the
  format: `.yaml` or `.yml` writes YAML, with the comments above, and
  `.json` writes JSON, which has no comments. Both hold the same Stubs.
  Its directory must exist. A name that starts with `.` is refused, since
  smock skips such files.
- `--base-path <path>`: a path to put in front of every path, in place of
  the paths of the document's servers, such as `/mock/petstore`. `/` means
  no prefix. It must start with `/` and hold no `?` or `#`. See [Servers and
  base paths](openapi/what-is-generated.md#servers-and-base-paths).
- `--overwrite on|off`: whether an existing `--output` is replaced. It is
  `off` by default: an existing file is refused before the document is
  read, and nothing is written.

The flags belong to one run, so none has an `SMOCK_` variable.

## Validate the document first

The command is not a validator. It reads the parts it imports, and an error
there stops it, but a mistake in a part it does not read, such as a request
body, does not. Check the document with a validator first, such as
[openapi-spec-validator](https://github.com/python-openapi/openapi-spec-validator),
which smock's own CI runs on the Admin API's document:

```sh
uvx --from openapi-spec-validator==0.9.0 openapi-spec-validator api/petstore.json
```

## The Mock and its Hosts

The file declares one Mock. How it shares the definitions directory with
other Mocks depends on what else the directory holds:

- **The only Mock.** The only Mock of a definitions directory is the
  Default Mock, which answers every request whatever its Host. It needs no
  Hosts, as in the [Quick start](#quick-start).
- **Several Mocks.** Each request goes to the Mock whose Hosts include its
  Host, and otherwise to the Default Mock ([Hosts and the Default
  Mock](definition-files.md#hosts-and-the-default-mock)). So give the
  imported Mock its Hosts with `--hosts`:

  ```sh
  smock import-openapi api/petstore.json --mock petstore --hosts petstore.test,pets.internal:8080 --output defs/petstore.yaml
  ```

  The file then declares:

  ```yaml
  mocks:
    - name: petstore
      hosts:
        - petstore.test
        - pets.internal:8080
  ```

  The document's `servers` never become Hosts. They name the real
  service, while the names that callers use for the Mock are a choice of
  each deployment.
- **The Mock's other fields.** To set `default`, `noMatch` or `journal`,
  declare the Mock by hand in another file, with its Hosts if it needs
  them:

  ```yaml
  # defs/petstore-mock.yaml
  version: 1
  mocks:
    - name: petstore
      default: true
      noMatch:
        status: 501
  ```

  Then import with `--declare-mock off`. The file then holds `version`
  and `stubs` only, and its Stubs belong to the Mock that the other file
  declares. `--hosts` is refused with it: give the Hosts where the Mock is
  declared.

  ```sh
  smock import-openapi api/petstore.json --mock petstore --declare-mock off --output defs/petstore.yaml
  ```

Each Host must be one a Definition file can declare, as `smock check`
checks it: a host name or an IP address, with a port of digits if any,
and no wildcard. A Host that is not one, or that is the same as another
once compared as smock compares Hosts (in lower case, without the port
and a trailing dot), is a usage error, so it never reaches the file. An
IPv6 address without brackets is the same Host as the bracketed one, so
`--hosts "[::1],::1"` is refused too ([Hosts and the Default
Mock](definition-files.md#hosts-and-the-default-mock)).

The command does not read the rest of the definitions directory. So run
`smock check` on the directory after importing: a Mock declared twice, a
Host used by two Mocks or a Stub ID used twice shows there. So does a file
imported with `--declare-mock off` whose Mock no file declares.

## Selecting responses

Without `Smock-Status`, a request gets [the main
response](openapi/what-is-generated.md#the-main-response). With it, it
gets the response whose key the header names, as the document writes it.
Take an operation with a 200 and a 404:

```json
"/pets/mine": {
  "get": {
    "operationId": "getPet",
    "responses": {
      "200": { "description": "My pet" },
      "404": { "description": "No pet" }
    }
  }
}
```

The file has a Stub for each response, the 404's first:

```yaml
stubs:
  # GET /pets/mine, 404
  - id: petstore.getPet.404
    mock: petstore
    request:
      method: GET
      path: /pets/mine
      headers:
        Smock-Status: "404"
    response:
      status: 404
  # GET /pets/mine, 200
  - id: petstore.getPet.200
    mock: petstore
    request:
      method: GET
      path: /pets/mine
    response:
      status: 200
```

```sh
curl localhost:8080/pets/mine                          # 200
curl -H "Smock-Status: 404" localhost:8080/pets/mine   # 404
curl -H "Smock-Status: 503" localhost:8080/pets/mine   # 200: no Stub names 503
```

- The value is the key as written: `404`, `4XX` or `default`. Only that
  exact key selects: `Smock-Status: 503` reaches neither `5XX` nor
  `default`.
- A value that no Stub names falls through to the main Stub. The Journal
  and the metrics name the Stub that answered, such as
  `petstore.getPet.404`.
- The main Stub comes after the other responses' Stubs, so it never
  shadows them, and `smock check` gives no warning.
- `Smock-Status` is an ordinary header condition. smock gives it no
  meaning of its own, and hand-written Stubs may use it too.

### Selecting examples

A response's first named example is its body. Each further named example has
a Stub of its own, which a request selects with `Smock-Example: <name>`,
alone for the main response, and after `Smock-Status` for another one
([Bodies from examples](openapi/what-is-generated.md#bodies-from-examples)).
Take a 200 whose examples are `cat`, then `dog`, and a 404 whose examples
are `missing`, then `gone`:

```json
"/pets/mine": {
  "get": {
    "operationId": "getPet",
    "responses": {
      "200": {
        "content": {
          "application/json": {
            "examples": {
              "cat": { "value": { "name": "Tom" } },
              "dog": { "value": { "name": "Rex" } }
            }
          }
        }
      },
      "404": {
        "content": {
          "application/json": {
            "examples": {
              "missing": { "value": { "message": "Pet not found" } },
              "gone": { "value": { "message": "Pet gone" } }
            }
          }
        }
      }
    }
  }
}
```

The file has four Stubs, in this order:

```yaml
stubs:
  # GET /pets/mine, 404, example gone
  - id: petstore.getPet.404.gone
    mock: petstore
    request:
      method: GET
      path: /pets/mine
      headers:
        Smock-Status: "404"
        Smock-Example: gone
    response:
      status: 404
      json:
        message: Pet gone
  # GET /pets/mine, 404, example missing
  - id: petstore.getPet.404
    mock: petstore
    request:
      method: GET
      path: /pets/mine
      headers:
        Smock-Status: "404"
    response:
      status: 404
      json:
        message: Pet not found
  # GET /pets/mine, 200, example dog
  - id: petstore.getPet.200.dog
    mock: petstore
    request:
      method: GET
      path: /pets/mine
      headers:
        Smock-Example: dog
    response:
      status: 200
      json:
        name: Rex
  # GET /pets/mine, 200, example cat
  - id: petstore.getPet.200
    mock: petstore
    request:
      method: GET
      path: /pets/mine
    response:
      status: 200
      json:
        name: Tom
```

```sh
curl localhost:8080/pets/mine                                                  # 200, Tom
curl -H "Smock-Example: dog" localhost:8080/pets/mine                          # 200, Rex
curl -H "Smock-Status: 404" localhost:8080/pets/mine                           # 404, Pet not found
curl -H "Smock-Status: 404" -H "Smock-Example: gone" localhost:8080/pets/mine  # 404, Pet gone
curl -H "Smock-Status: 404" -H "Smock-Example: lost" localhost:8080/pets/mine  # 404, Pet not found
curl -H "Smock-Example: gone" localhost:8080/pets/mine                         # 200, Tom
```

- The value is the example's name as the document writes it.
- Within an operation, the Stubs come in this order, so that none shadows
  another: the further named examples of each other response, with both
  headers; the other responses, with `Smock-Status`; the further named
  examples of the main response, with `Smock-Example`; then the main
  Stub.
- A value that no Stub names falls through. An unknown `Smock-Example`
  with `Smock-Status: 404` gets the 404's first example, and an unknown
  one alone gets the main Stub. So does `Smock-Example: gone` alone, since
  `gone` is the 404's.
- A name that a request cannot send as a header value gets no Stub of its
  own, with a warning. Such a name is empty, holds a character other than
  visible ASCII and space, or starts or ends with a space. As the first
  example, it still gives the response's body, and the Stub's comment
  quotes it.
- `Smock-Example` is an ordinary header condition too, which hand-written
  Stubs may use.

### Through the system under test

A test whose requests reach the Mock through the system under test
cannot set `Smock-Status` or `Smock-Example` on them. Instead, it adds an
Ephemeral Stub for its Session through the Admin API: the generated Stub's
method, path and `response`, without the two headers. The Session's
requests then get that
response, and other Sessions still get the main one. The system under
test must pass the Session on, in the `baggage` header of its calls
([Sessions and Ephemeral Stubs](admin-api.md#sessions-and-ephemeral-stubs)).
Below, the second `curl` stands for such a call:

```sh
curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=pet-missing" \
  -d '{"request":{"method":"GET","path":"/pets/mine"},"response":{"status":404}}' \
  localhost:9090/v1/mocks/petstore/stubs
curl -H "baggage: smock-session=pet-missing" localhost:8080/pets/mine   # 404
curl -H "baggage: smock-session=other" localhost:8080/pets/mine         # 200, from the file
curl localhost:8080/pets/mine                                           # 200, from the file
```

When the test is done, it deletes the Ephemeral Stub, or resets its
Session with `POST /v1/reset` and `{"scope":"session"}`.

## Regenerating

The command owns the file it writes. When the document changes, run it
again with `--overwrite on`:

```sh
smock import-openapi api/petstore.yaml --mock petstore --output defs/petstore.yaml --overwrite on
```

- A re-import replaces the whole file. It does not merge with hand edits:
  they are lost, which is why the file's first comment says not to edit
  it.
- Without `--overwrite on`, an existing `--output` is refused before the
  document is read, and nothing is written. So a mistyped path never
  replaces a hand-written file. A file that appears at `--output` while
  the command runs is not replaced either.
- The file is written to a temporary file in the same directory, such as
  `.petstore.yaml.tmp`, then renamed to `--output`. smock skips names
  that start with `.`, so a smock that watches the directory loads the old
  file or the new one, never half a file. The temporary file is removed
  when anything fails. The command reads, creates and changes no other
  file in the directory.
- A temporary file that exists already, such as one another run is
  writing, is never touched: the command tries the next name instead,
  `.petstore.yaml.tmp1`, then `.petstore.yaml.tmp2`, and so on up to
  `.petstore.yaml.tmp99`. When all 100 names exist, nothing is written:
  the error about `--output` says `the temporary files .petstore.yaml.tmp
  to .petstore.yaml.tmp99 all exist`, and the exit status is 1.
- Some outputs are refused even with `--overwrite on`: a directory, a
  symlink (even to a regular file), and the document itself or a file
  its references name, which would be replaced by its own conversion. A
  file that references name is known only once it is read, so that
  refusal comes after the conversion, just before the file would be
  written. The directory of `--output` must exist: the command makes no
  directory. Each refusal is an error about `--output`, with exit status
  1.

### Overrides

Put hand changes in another file of the same directory. Generated Stubs
have no `priority`, so a hand-written Stub with any `priority` is tried
first, and the next import leaves its file alone. This override is for
the `/pets/mine` operation of [Selecting responses](#selecting-responses),
imported into `defs/petstore.yaml`:

```yaml
# defs/petstore-overrides.yaml
version: 1
stubs:
  - id: petstore.getPet.none
    mock: petstore
    priority: 1
    request:
      method: GET
      path: /pets/mine
    response:
      status: 404
      json:
        message: You have no pet
```

`smock check defs` then warns about each generated Stub that the
override shadows. That is expected:

```
petstore.yaml: /stubs/0: warning: the Stub "petstore.getPet.404" can never match: the Stub "petstore.getPet.none" at petstore-overrides.yaml: /stubs/0 is tried first and matches every request this one would
petstore.yaml: /stubs/1: warning: the Stub "petstore.getPet.200" can never match: the Stub "petstore.getPet.none" at petstore-overrides.yaml: /stubs/0 is tried first and matches every request this one would
```

An override that matches on method and path only also wins over the
Stubs that `Smock-Status` and `Smock-Example` select, as the first warning
shows.

The warning comes only for a generated Stub whose path is exact, as
`/pets/mine` is. `smock check` does not compare two patterns. So an
override of a templated path, written with the generated Stubs' pattern,
such as `path: { pattern: /v1/pets/[^/]+ }` for the quick start's
`/pets/{petId}`, gives no warning, though it shadows them just the same.

### Checking that the file is current

In CI, run the command again from a fixed directory, such as the root of
the repository, then let Git check that the file did not change:

```sh
smock import-openapi api/petstore.yaml --mock petstore --output defs/petstore.yaml --overwrite on
git diff --exit-code defs/
```

The same document and flags give the same bytes, so `git diff` fails
only when the committed file is out of date with the document. Running
from a fixed directory keeps the relative paths naming the same files.

## Problems and exit codes

Each problem is one line on stdout, in the form `smock check` uses:

```
api/petstore.json: /paths/~1pets/get/responses/200/content/application~1xml: warning: left out: a response answers with one media type, here "application/json"
```

- The document is named as given on the command line, and another file that
  references name as [References to other
  files](openapi/references-and-yaml.md#references-to-other-files) says. The
  place is an [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901) JSON
  Pointer to where the construct is written, after following `$ref`. In a
  pointer, `/` in a key is written `~1`, so `/paths/~1pets` is the path key
  `/pets`.
- Errors have no `warning:`. An error is what makes a faithful file
  impossible, such as invalid JSON, an unsupported version, a reference
  that cannot be followed, a malformed path, a field of the wrong type or
  IDs that collide. A warning names a part of the document that was left
  out or changed; the file still serves the rest.
- Problems with `--output` come first, named by `--output` as given, with
  no pointer. Then the document-level ones, among them the files that
  cannot be read. Then each operation's, in the order the document writes
  the operations, whatever the order of their Stubs, and within an
  operation in the order of its responses.
- One summary line ends the output: `wrote <file>: <n> Stubs from <m>
  operations, <w> warnings`, or `nothing written: <e> errors`.

| Exit status | Meaning |
|---|---|
| 0 | The file was written, with or without warnings. |
| 1 | Nothing was written: the document or the output had an error. |
| 2 | A usage error, such as a missing flag or a document outside `--ref-dir`, printed on stderr. |

The input must be UTF-8 JSON, or YAML as [How YAML is
read](openapi/references-and-yaml.md#how-yaml-is-read) says. A leading byte
order mark is skipped. A key that repeats in an object is an error at its
pointer, as in a Definition file. `openapi` must be a string
`3.<minor>.<patch>`, such as `"3.1.0"`, for 3.0, 3.1 or 3.2; the patch is
ignored. A Swagger 2.0 document is an error: convert it to OpenAPI 3.0
first.

Before it writes, the command loads its own output with the loader
`smock check` uses, as a set of its own. With `--declare-mock off`, a
stand-in file declares the Mock, as the hand-written one would. The output
must be valid and give no warning. If not, nothing is written, and the
message calls it a smock bug, with the file and the pointer of the
problem: please report it.

The same document and flags always give the same bytes, on every
platform, so a generated file changes only when the document or the
command does.

## Notes for Mockoon users

Mockoon imports an OpenAPI document into an environment too, and its CLI
can serve a document directly. An environment that Mockoon built from a
document can be replaced by importing the same document into smock. The
result differs from Mockoon 9.9.0's import in these ways:

- **One fixed sample.** Mockoon turns a schema into faker helpers, which
  give new data on every request. smock writes one fixed sample of the
  schema in the file ([Samples from
  schemas](openapi/what-is-generated.md#samples-from-schemas)), so a
  reviewer sees what the Mock answers, and tests repeat.
- **The default response.** smock answers the lowest 2xx response, else
  `2XX`, else `default` ([The main
  response](openapi/what-is-generated.md#the-main-response)). Mockoon
  answers each route's first response, the one with the lowest status code,
  else `default`. So an operation with `default` or `2XX`, and a `404`,
  answers 404 in Mockoon and 200 in smock. Mockoon's first response also has
  a body made from the schema, even when the document gives examples, while
  smock's has the first example.
- **Ranges and `example`.** Mockoon drops range keys such as `4XX`, and
  reads a media type's `examples` but not its `example`. smock keeps both: a
  range answers its first code, and `example` gives the body ([Bodies from
  examples](openapi/what-is-generated.md#bodies-from-examples)).
- **Concrete paths first.** Mockoon keeps the document's order of paths, so
  `/pets/{petId}`, written before `/pets/mine`, answers `GET /pets/mine`.
  smock puts concrete paths before templated ones ([Paths with
  parameters](openapi/what-is-generated.md#paths-with-parameters)).
- **The other responses.** Mockoon's imported responses have no rules, so
  only the first one answers until the route is edited. In smock, a request
  selects any other response with `Smock-Status`, and a named example with
  `Smock-Example` ([Selecting responses](#selecting-responses)).
- **Serving and re-importing.** `mockoon-cli start --data openapi.yaml`
  converts the document each time it starts. smock never reads OpenAPI
  when it serves: import once, commit the file, and import again with
  `--overwrite on` when the document changes. Mockoon's app adds only
  missing routes and status codes on a re-import, while smock replaces the
  whole file, and Git shows what changed ([Regenerating](#regenerating)).
- **Hosts, not ports.** Mockoon tells environments apart by port, and
  smock tells Mocks apart by Host. When the definitions directory holds
  other Mocks, import with `--hosts`
  ([The Mock and its Hosts](#the-mock-and-its-hosts)).

What was changed in Mockoon after the import, such as rules, goes in an
override file ([Overrides](#overrides)), translated as
[Migrating from Mockoon](migrating-from-mockoon.md) shows.

## Notes for Prism users

Prism serves an OpenAPI document as it is, and a request picks a response
with the `Prefer` header. smock's import answers the same main response
as Prism: the lowest 2xx, then `default`. Port each `Prefer` header to the
two selector headers ([Selecting responses](#selecting-responses)):

| Prism | smock |
|---|---|
| `Prefer: code=404` | `Smock-Status: 404` |
| `Prefer: example=dog` | `Smock-Example: dog` |
| `Prefer: code=404, example=gone` | `Smock-Status: 404` and `Smock-Example: gone` |
| The query parameters `__code` and `__example` | No counterpart: send the headers. |

Where the two differ, as checked against Prism 5.16.0:

- **Only the key as written selects.** Prism answers `Prefer: code=405`
  with the `4XX` response, or else `default`, sent with status 405.
  `Smock-Status: 405` reaches neither: send `Smock-Status: 4XX`, which
  answers 400.
- **An unknown value falls through.** Prism answers a code or an example
  that the document does not have with a 404 error. smock answers the
  main response, or the selected response's first example, and the
  Journal names the Stub that answered.
- **No request validation.** Prism checks parameters, bodies and security,
  and answers an invalid request with an error such as 422. smock's Stubs
  match on method and path only, so every request gets the documented
  answer.
- **No dynamic mode.** Prism's `--dynamic` generates a body for each
  request. smock writes one fixed sample.
- **The file is the source.** Prism serves the document and reloads it
  when it changes. smock serves the generated file: import again with
  `--overwrite on`, and review the diff ([Regenerating](#regenerating)).

## Limits

- At most 1,000 documents are read, the document given included, and at
  most 64 MiB in all. Passing either is an error. Both parsers build a
  tree, and the YAML parser copies the text into 4-byte characters, so
  a run takes many times what it reads in memory.
- The file is at most 64 MiB. A larger output is an error that gives its
  size, and nothing is written.
- A large output needs room where smock runs. `smock serve` holds the whole
  file in memory, parsed, as it holds every Definition file, and while it
  reloads a changed file it holds the old set and the new one, so give the
  Pod memory for both. A ConfigMap holds at most 1 MiB, so deploy a larger
  file with the Helm chart's [git-sync
  sidecar](../charts/smock/README.md#from-a-git-repository-git-sync) or its
  [OCI image volume](../charts/smock/README.md#from-an-oci-image) instead.
- A sampled array has at most 100 items. A larger `minItems` gives 100
  items, with a warning.
- A sample nests at most 32 levels. An object or an array inside 32 others
  is null ([Schema references and
  recursion](openapi/what-is-generated.md#schema-references-and-recursion)).
- A sample whose compact JSON would pass 64 KiB is made again, cut to its
  required parts below its first level. When that would pass 1 MiB, the body
  is left empty, with a warning ([Sample
  size](openapi/what-is-generated.md#sample-size)).
- A bound of a sampled number has at most 18 digits before the point and
  18 after. A bound with more is ignored, with a warning
  ([Numbers](openapi/what-is-generated.md#numbers)).
- The file nests at most 1024 levels, the most the parsers read. A value
  of `const`, `examples`, `example`, `default` or `enum`, or an
  example's value, that would nest deeper is left out of its body, with a
  warning.
- An example body is at most 1 MiB, its compact JSON or its text. A
  larger one is left empty, with a warning.
- Each operation at a templated path adds pattern Stubs, one per response
  and named example. The match index does not find them ([Which Stub
  answers](definition-files/matching.md#which-stub-answers)), so each
  request of that method scans the Mock's pattern Stubs, in order. A
  document with many templated paths makes each request slower.
