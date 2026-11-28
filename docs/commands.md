# Commands

The `smock` binary has four commands beside `help`. `smock` alone,
`smock help` and `smock --help` print a usage that lists them, and exit
with status 0. `smock serve` runs the server, and [Running
smock](running.md) describes it. This document
describes the three that read or write Definition files without serving:
[`smock check`](#smock-check), [`smock render`](#smock-render) and
[`smock import-openapi`](#smock-import-openapi), whose guide is
[Importing OpenAPI](importing-openapi.md).

The examples use the `defs` directory and the `get-user` Stub of the
README's quick start ([Run](../README.md#run)), and a `sample.json` that
holds `{"path": "/users/1"}`. The Definition-file reference has longer
accounts of the first two commands: [Checking a definitions
directory](definition-files.md#checking-a-definitions-directory) says what
`smock check` checks and warns about, and [Rendering a
template](definition-files/templates.md#rendering-a-template) says what a
rendering shows.

## `smock check`

`smock check defs` validates a definitions directory the way `smock serve`
loads it: it prints every problem, one per line with the file and a JSON
Pointer, and exits with status 1 if there is any. It also warns about Stubs
that can never match, because an earlier Stub always matches first, and
about a [state that a Stub requires but no Stub moves its Scenario
to](definition-files.md#a-state-that-no-stub-moves-to); warnings do
not change the exit status. It reads the Descriptor set that each Mock
names, and checks every gRPC Stub against its method's types
([gRPC Stubs](definition-files/grpc.md#grpc-stubs)). It takes
`--body-file-dir`, `--template-env` and `--header-size-limit` as
`smock serve` does ([Settings](running.md#settings)), and reads the
listed environment variables from its own environment.

## `smock render`

`smock render --dir defs get-user --request sample.json` shows what a Stub
returns for a sample request before a test relies on it. The sample is JSON,
`{method, path, query, headers, body, session, vars, data}`, every member
optional (`GET /` without query, headers, body, Session, Variables or
data); the path and the query values are given percent-decoded, as Stub
conditions compare them, and a repeated parameter or header takes an array
of values. Cookies come
from `headers.Cookie`, as a request's come from its `Cookie` fields, and
form fields from the body, read as a form when `headers.Content-Type` says
it is one. `vars` maps the name of each
[Variable](definition-files/variables.md#variables) templates read to its value;
a rendering never reads the live Variables. `data` maps the name of each
[Data bucket](definition-files/data-buckets.md#data-buckets) of the Stub's Mock
to the value templates read in place of its initial value; a rendering
never reads a Session's copy. smock reads the directory as
`smock serve` does, body files included. It takes `--body-file-dir`,
`--template-env` and `--header-size-limit` as `smock serve` does
([Settings](running.md#settings)), and reads the listed environment
variables from its own environment. It prints the rendering as JSON, the
same as the [Admin render operation](admin-api.md#rendering-a-stub)'s
result without its `warnings`: the Stub's status, headers and body
(`utf-8` text, or `base64`) or its Server-Sent Events, and the conditions
the sample fails, with expected and actual values as in a Near miss (empty
when it meets them all). The Stub is
rendered even when the sample fails them, and a
[templated](definition-files/templates.md#templates) response is rendered for the
sample. An [LLM response](definition-files/llm-responses.md#llm-responses) shows the
reply the sample's body asks for: the JSON body, or a stream's events,
each with its wait. A [gRPC Stub](grpc/rendering-and-journal.md#rendering-a-grpc-stub)
renders as a call to its method, whatever the sample's method and
Content-Type, which are only conditions: the sample's body is the request
message as JSON, checked against the method's input type, and the
rendering shows the reply message as JSON, its initial metadata, and its
gRPC status, message, trailing metadata and error details as
`response.grpc`, never protobuf bytes. `--time` (RFC 3339) and `--seed` fix the clock and the
random source of the rendering; without a seed, it uses the Stub's
`fault.seed`, or a fresh one. A Stub with
[`responses`](definition-files/responses.md#several-responses) renders the one
the seed picks, and `--response <i>` renders the one at index `i`, from 0.
The rendering shows the `time`, the `seed` and the `responseIndex` it used,
so it can be repeated exactly, and a template that fails for the sample
shows the 500 a request would get and its `templateError`. It also shows, as
`variables`, the values the Stub's `variables` would write, rendered against
the sample's `vars`, and the response reads them written over the sample's
`vars`. It shows, as `dataWrites`, the writes the Stub's `dataWrites` would
make on the sample's data, and the response reads the data after them. A
[CRUD Stub](definition-files/crud-stubs.md#crud-stubs) renders the answer its
operation would give from the sample's data, and shows its write, if it
makes one, in `dataWrites`. It writes nothing. It exits with status 1,
with the problem on stderr, for:

- an invalid definitions directory, with the messages `smock check`
  prints;
- an unknown Stub ID, or an index the Stub has no response at;
- a sample that cannot be read or is not valid;
- sample data for a bucket the Stub's Mock does not declare, or that
  breaks a keyed bucket's rules;
- a sample whose method and path fit no operation of a CRUD Stub;
- a sample whose body is not a message of a gRPC Stub's input type, as
  JSON.

## `smock import-openapi`

`smock import-openapi api/petstore.yaml --mock petstore --output defs/petstore.yaml`
converts an OpenAPI 3.0, 3.1 or 3.2 document into one Definition file,
once. The file is committed and reviewed like any other, and smock never
reads OpenAPI when it serves. The file declares one Mock, with a Stub for
each documented response of each operation, which matches the operation's
method and path. Each body comes from the document's examples, else from
one fixed sample of the schema. The main response, the lowest 2xx when
there is one, answers by default. A request selects another response with
`Smock-Status: <key>`, such as `Smock-Status: 404`, and a further named
example with `Smock-Example: <name>`. The document is JSON (`.json`) or
YAML 1.2 (`.yaml`, `.yml`), and its references are followed only into
local files. The flags belong to one run, so none has an `SMOCK_`
variable:

| Flag | What it sets |
|---|---|
| `--mock <name>` | Required: the name of the Mock the file declares. Every Stub ID starts with it. |
| `--output <file>` | Required: the Definition file to write. `.yaml` or `.yml` writes YAML, with comments that map each Stub back to the document, and `.json` writes JSON. Its directory must exist. |
| `--hosts <h1,h2>` | The Mock's Hosts, separated by commas. None by default: the only Mock of a definitions directory is the Default Mock and needs none. With `--declare-mock on`, an empty `--hosts ""` gives none too, as leaving it out does. The document's `servers` never become Hosts. |
| `--declare-mock on\|off` | `on` by default. `off` writes only the Stubs, for a Mock declared by hand in another file. |
| `--base-path <path>` | A path to put in front of every path, such as `/mock/petstore`, in place of the path of the document's server. |
| `--ref-dir <dir>` | The directory that references to other files are followed in, by default the document's own. A reference that leads outside it is an error. |
| `--overwrite on\|off` | `off` by default: an existing `--output` is refused before the document is read. `on` replaces it, to import a changed document again. |

It prints every problem as `smock check` does, one per line with the file
and a JSON Pointer into the document, then a summary line,
`wrote <file>: <n> Stubs from <m> operations, <w> warnings` or
`nothing written: <e> errors`. It exits with status 0 when it wrote the
file, warnings or not, 1 when it wrote nothing, and 2 for a usage error.
It writes the file to a temporary file whose name starts with `.`, then
renames it, so a smock that watches the directory never loads half a file.
Run `smock check` on the directory afterwards: the command does not read
the other files there.
[docs/importing-openapi.md](importing-openapi.md) and its documents
describe what is generated, selecting responses, regenerating and the
limits, with notes for Mockoon and Prism users.
