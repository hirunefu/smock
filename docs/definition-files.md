# Definition files

Definition files declare the Mocks smock serves and their Stubs. They live
in a definitions directory, such as `defs/`, that `smock serve --dir` and
`smock check` read:

- The Definition files are the regular files at the top level whose names
  end in `.json`, `.yaml` or `.yml`. Symlinks are followed. A YAML file
  means exactly what the equivalent JSON file means; smock accepts only the
  safe subset of YAML that [Writing Definition files in
  YAML](#writing-definition-files-in-yaml) describes.
- Names that start with `.` are skipped, which covers the `..data` entries
  of Kubernetes ConfigMap volumes.
- smock reads the files in byte-wise order of their names, and reads them
  together, as one definition set: a Stub can belong to a Mock that another
  file declares.
- Body files live in the body-file subdirectory, `files/` by default
  (`--body-file-dir`, `SMOCK_BODY_FILE_DIR`), and so do the JSON files of
  [Data buckets](definition-files/data-buckets.md#data-buckets). smock reads
  them when it loads the Definition files, and serves them from memory.
  Symlinks inside it are followed while they stay inside it; one that leads
  a file or a directory outside it is a problem, so that nothing outside is
  served.

This document and the documents under `definition-files/` describe the
format: how Stubs match requests (method, path, query parameters, headers,
cookies and body, exactly, by RE2 pattern, as JSON, by form field or by
paths into XML, negated or by presence with `$not` and `$exists`, and by
array element with `$includes` and `$last`), the order they are tried in
(priority, then file-name order), what a Mock answers when nothing matches,
responses with inline bodies, body files that serve byte ranges, JSON or
Server-Sent Events, LLM responses in an LLM API's wire form, several
responses picked at random by weight (`responses`), response templates and
their helpers (fake data, time and dates, conversions, strings, encodings,
JWTs and arithmetic), Variables that keep a value from one request for the
next, Data buckets that a Mock declares with their initial values and that
each Session reads and writes in a copy of its own, CRUD Stubs that serve a
bucket as a REST resource with filters, sorting and paging, Faults, the JSON
Schema, editor support and writing Definition files in another configuration
language. This document keeps what concerns the definitions directory and
the definition set as a whole: Hosts and the Default Mock, the JSON Schema,
reloading, `smock check` and its warnings, YAML, editor support and other
configuration languages. Each document under `definition-files/` describes
one part of the format, from how a Stub matches a request to gRPC, and the
[Contents](#contents) lists them.
[migrating-from-mockoon.md](migrating-from-mockoon.md) turns a Mockoon
environment into Definition files.

## Contents

In this document:

- [Hosts and the Default Mock](#hosts-and-the-default-mock)
- [The JSON Schema](#the-json-schema)
- [Reloading](#reloading)
- [Checking a definitions directory](#checking-a-definitions-directory)
  - [Warnings](#warnings)
- [Writing Definition files in YAML](#writing-definition-files-in-yaml)
- [Editor support](#editor-support)
- [Writing Definition files in another configuration language](#writing-definition-files-in-another-configuration-language)

In the documents under `definition-files/`:

- [How a Stub matches a request](definition-files/matching.md)
  - [Pattern conditions](definition-files/matching.md#pattern-conditions)
  - [Negation and presence](definition-files/matching.md#negation-and-presence)
  - [Operators in json conditions](definition-files/matching.md#operators-in-json-conditions)
  - [Cookies](definition-files/matching.md#cookies)
  - [Form fields](definition-files/matching.md#form-fields)
  - [XML bodies](definition-files/matching.md#xml-bodies)
  - [Which Stub answers](definition-files/matching.md#which-stub-answers)
  - [When no Stub matches](definition-files/matching.md#when-no-stub-matches)
  - [Turning the Journal off for a Mock](definition-files/matching.md#turning-the-journal-off-for-a-mock)
- [Scenarios](definition-files/scenarios.md)
  - [An example](definition-files/scenarios.md#an-example)
  - [When the state moves](definition-files/scenarios.md#when-the-state-moves)
  - [Sessions and Ephemeral Stubs](definition-files/scenarios.md#sessions-and-ephemeral-stubs)
  - [How state grows](definition-files/scenarios.md#how-state-grows)
  - [Seeing what moved](definition-files/scenarios.md#seeing-what-moved)
- [Responses](definition-files/responses.md)
  - [Range requests](definition-files/responses.md#range-requests)
  - [Server-Sent Events](definition-files/responses.md#server-sent-events)
  - [JSON bodies](definition-files/responses.md#json-bodies)
  - [Several responses](definition-files/responses.md#several-responses)
- [Faults](definition-files/faults.md)
  - [Delays](definition-files/faults.md#delays)
  - [Connection Faults](definition-files/faults.md#connection-faults)
  - [Seeds](definition-files/faults.md#seeds)
- [LLM responses](definition-files/llm-responses.md)
  - [Streams](definition-files/llm-responses.md#streams)
  - [Chunks](definition-files/llm-responses.md#chunks)
  - [Timing](definition-files/llm-responses.md#timing)
  - [Usage and stop reasons](definition-files/llm-responses.md#usage-and-stop-reasons)
  - [Ids, seeds and time](definition-files/llm-responses.md#ids-seeds-and-time)
  - [Templates in LLM replies](definition-files/llm-responses.md#templates-in-llm-replies)
  - [The size bound](definition-files/llm-responses.md#the-size-bound)
  - [Paths and compatible endpoints](definition-files/llm-responses.md#paths-and-compatible-endpoints)
  - [Model lists and other paths](definition-files/llm-responses.md#model-lists-and-other-paths)
  - [Prompts in the Journal](definition-files/llm-responses.md#prompts-in-the-journal)
- [Tool calls and agent loops](definition-files/llm-tool-calls.md)
  - [Tool calls](definition-files/llm-tool-calls.md#tool-calls)
  - [Agent loops](definition-files/llm-tool-calls.md#agent-loops)
- [The OpenAI Responses and Anthropic Messages APIs](definition-files/llm-apis.md)
  - [OpenAI Responses](definition-files/llm-apis.md#openai-responses)
  - [Anthropic Messages](definition-files/llm-apis.md#anthropic-messages)
- [LLM API errors](definition-files/llm-errors.md)
  - [Mid-stream errors](definition-files/llm-errors.md#mid-stream-errors)
  - [Errors before the reply](definition-files/llm-errors.md#errors-before-the-reply)
- [Templates](definition-files/templates.md)
  - [Inserting values](definition-files/templates.md#inserting-values)
  - [Structured templates](definition-files/templates.md#structured-templates)
  - [Escaping and line breaks](definition-files/templates.md#escaping-and-line-breaks)
  - [Missing values and render errors](definition-files/templates.md#missing-values-and-render-errors)
  - [Environment variables](definition-files/templates.md#environment-variables)
  - [Errors when loading](definition-files/templates.md#errors-when-loading)
  - [Rendering a template](definition-files/templates.md#rendering-a-template)
- [Template helpers](definition-files/template-helpers.md)
  - [Fake data](definition-files/template-helpers.md#fake-data)
  - [Time](definition-files/template-helpers.md#time)
  - [Conversions](definition-files/template-helpers.md#conversions)
  - [Strings](definition-files/template-helpers.md#strings)
  - [Arrays](definition-files/template-helpers.md#arrays)
  - [Encodings](definition-files/template-helpers.md#encodings)
  - [JWTs](definition-files/template-helpers.md#jwts)
  - [Dates](definition-files/template-helpers.md#dates)
  - [How helpers read their arguments](definition-files/template-helpers.md#how-helpers-read-their-arguments)
  - [Arithmetic](definition-files/template-helpers.md#arithmetic)
  - [The random source and the time of a request](definition-files/template-helpers.md#the-random-source-and-the-time-of-a-request)
- [Variables](definition-files/variables.md)
  - [When Variables are written](definition-files/variables.md#when-variables-are-written)
  - [Reading Variables](definition-files/variables.md#reading-variables)
  - [Through the Admin API](definition-files/variables.md#through-the-admin-api)
  - [Resets and reloads](definition-files/variables.md#resets-and-reloads)
  - [The state bound](definition-files/variables.md#the-state-bound)
- [Data buckets](definition-files/data-buckets.md)
  - [Declaring a bucket](definition-files/data-buckets.md#declaring-a-bucket)
  - [Initial values](definition-files/data-buckets.md#initial-values)
  - [Keys and key texts](definition-files/data-buckets.md#keys-and-key-texts)
  - [Reading buckets in templates](definition-files/data-buckets.md#reading-buckets-in-templates)
  - [Session copies](definition-files/data-buckets.md#session-copies)
  - [Writing buckets: `dataWrites`](definition-files/data-buckets.md#writing-buckets-datawrites)
  - [Data buckets through the Admin API](definition-files/data-buckets.md#data-buckets-through-the-admin-api)
  - [Copies in resets and reloads](definition-files/data-buckets.md#copies-in-resets-and-reloads)
  - [Copies and the state bound](definition-files/data-buckets.md#copies-and-the-state-bound)
- [CRUD Stubs](definition-files/crud-stubs.md)
  - [The shape of a CRUD Stub](definition-files/crud-stubs.md#the-shape-of-a-crud-stub)
  - [CRUD paths](definition-files/crud-stubs.md#crud-paths)
  - [Reads](definition-files/crud-stubs.md#reads)
  - [List queries](definition-files/crud-stubs.md#list-queries)
  - [Writes](definition-files/crud-stubs.md#writes)
  - [When a CRUD Stub writes](definition-files/crud-stubs.md#when-a-crud-stub-writes)
  - [Order and overrides](definition-files/crud-stubs.md#order-and-overrides)
  - [A CRUD Stub's Near miss](definition-files/crud-stubs.md#a-crud-stubs-near-miss)
  - [CRUD headers](definition-files/crud-stubs.md#crud-headers)
  - [Faults on a CRUD Stub](definition-files/crud-stubs.md#faults-on-a-crud-stub)
  - [CRUD Stubs in the Journal](definition-files/crud-stubs.md#crud-stubs-in-the-journal)
  - [Ephemeral CRUD Stubs](definition-files/crud-stubs.md#ephemeral-crud-stubs)
  - [CRUD Stubs that do not load](definition-files/crud-stubs.md#crud-stubs-that-do-not-load)
- [gRPC in Definition files](definition-files/grpc.md)
  - [Descriptor sets](definition-files/grpc.md#descriptor-sets)
  - [The health service](definition-files/grpc.md#the-health-service)
  - [Reflection](definition-files/grpc.md#reflection)
  - [gRPC Stubs](definition-files/grpc.md#grpc-stubs)
  - [The status of a gRPC reply](definition-files/grpc.md#the-status-of-a-grpc-reply)
  - [gRPC reply metadata](definition-files/grpc.md#grpc-reply-metadata)
  - [gRPC error details](definition-files/grpc.md#grpc-error-details)
  - [gRPC Stub conditions](definition-files/grpc.md#grpc-stub-conditions)

## Hosts and the Default Mock

One smock can stand in for several services. Each Mock lists the Hosts it
answers to, and a request goes to the Mock whose `hosts` include its Host:

```yaml
mocks:
  - name: users
    hosts: [users.example.com, "users:8080"]
    default: true
  - name: orders
    hosts: [orders.example.com]
```

- A request's Host is the authority of an absolute-form target, such as
  `GET http://orders.example.com/orders/1 HTTP/1.1`, or else its `Host`
  header. Over [HTTP/2](http2.md), it is `:authority`, or else the `host`
  field. A request that sends both, naming different Hosts, gets 400
  ([Requests smock refuses](http2.md#requests-smock-refuses)).
- No `host` field is added for `:authority`: `header.host` and a `host`
  header condition see only a `host` field the client sent. An HTTP/2
  client that gives its Host by `:authority` alone sends none, so tell
  Hosts apart with each Mock's `hosts`.
- Hosts are exact names, with no wildcards. They are compared
  case-insensitively, without the port and without a trailing dot, so
  `Users.Example.com.:8080` is the Host `users.example.com`. An IPv6 address
  is written in brackets, such as `[::1]:8080`. An IPv6 address without a
  port may also be written without brackets, and is then the same Host as
  the bracketed one: `::1` is the Host `[::1]`. Without brackets every
  colon belongs to the address, so `::1:8080` is the Host `[::1:8080]`, not
  `[::1]` with the port 8080; a port needs the brackets (`[::1]:8080`).
- A Host is written as a request's `Host` header carries it, so a port is
  digits, and nothing but a port follows a bracketed address. A Host that
  leaves no name once normalised, such as `.` or `:8080`, could never match
  and is rejected.
- Each Host belongs to at most one Mock. The same Host repeated within one
  Mock is fine.

A request whose Host no Mock lists, or that has none (HTTP/1.0 and HTTP/2
allow that), goes to the Default Mock:

- the Mock marked `default: true`; at most one Mock may be marked;
- otherwise the only Mock, when the definition set declares exactly one, so
  a single Mock answers on `localhost` without any `hosts`;
- with no Mock declared at all, including an empty or missing definitions
  directory, smock serves one empty Default Mock named `default`, with no
  Hosts.

Every response the Default Mock sends because no Host matched, including
its no-match response, carries a header that says so, so that a mistyped
Host does not silently succeed:

```http
Smock-Mock: users; via=default
```

The header is ASCII: a Mock name that is not an HTTP token has its other
bytes percent-encoded, as in `%E3%83%A6...%20API`. A request for one of the
Default Mock's own Hosts gets no header.

Without a Default Mock, such a request gets a 404 that names its Host and
every Host the Mocks declare, both normalised:

```json
{"error":"no Mock for this Host","host":"usres.example.com","acceptedHosts":["users.example.com","users","orders.example.com"]}
```

`host` is `null` for a request without a Host. A gRPC call gets
UNIMPLEMENTED `no Mock for this Host` instead, in gRPC's form
([The call's Mock](grpc.md#the-calls-mock)).

## The JSON Schema

The format of Definition files is published as a JSON Schema, one per
format version. The Schema of version 1 is at

<https://hirunefu.github.io/smock/schema/v1/definitions.json>

and that URL is also its `$id`. Its source is
[`schema/v1/definitions.json`](../schema/v1/definitions.json). A file
without `version` is read as version 1; any other version is rejected.

The Schema describes every field of format version 1, and smock implements
them all. smock rejects any field the Schema does not define, so that a
file never means something smock silently ignores.

## Reloading

`smock serve` polls the definitions directory, body-file subdirectory
included, every second, and reloads the definition set when its files
change, without a restart:

- Adding, editing, renaming or removing a Definition file or a body file
  triggers a reload. So does a Kubernetes ConfigMap update, which swaps the
  `..data` symlink and keeps the visible names. Any change to a name in the
  directories or to the times of a file smock reads counts, so a reload
  can also find nothing new, as when a file is written again with the same
  bytes. Names that start with `.` do not count.
- When a poll finds a change, smock waits for the files to settle. It
  looks again every 250 ms, and reads them once they have stayed the same
  for 250 ms. So a change made of several writes, such as a `git checkout`
  of several files, gives one reload of them all. Files that never stay
  the same for 250 ms are read 10 s after the change was first seen.
- A change is reloaded within about the poll interval plus 250 ms. In a
  measurement of 12 edits of a body file, the new body was served 0.4 s to
  1.2 s after the edit, 0.8 s at the median. A few changes are found
  within 10 s instead: on NFS, one that the client's attribute cache still
  hides from the first look of a poll (below), and a symlink pointed at
  another file with the very same times.
- Writes more than 250 ms apart can still be read apart. smock then
  reloads the part it finds, or reports the set as invalid and keeps
  serving the current one, and reloads the rest once it has settled. To
  make a change of several files one step, write them into a new directory
  and swap a symlink to it, as a ConfigMap update and git-sync do.
- When `--dir` goes through a symlink that is pointed at a new directory,
  as git-sync does for each commit (`--dir /git/current/mocks`), the next
  poll finds the new directory, whether the old one is removed, as git-sync
  does by default, or stays, as with git-sync's `--stale-worktree-timeout`.
- A definitions directory that does not exist yet is polled until it
  appears.
- smock polls instead of using file events because the file watcher of
  moonbitlang/async, the runtime it is built on, can abort the process
  when files are created and written in a directory it watches
  ([smock#264](https://github.com/hirunefu/smock/issues/264),
  [moonbitlang/async#725](https://github.com/moonbitlang/async/issues/725)).
  smock polls alone until a release of the runtime fixes that.
- A poll first takes the change time of each file smock reads and of
  each directory it lists, with one call each, and is done when none
  changed. Otherwise, and at least every 10 s, it compares the names in
  the directories, where each file really is once symlinks are resolved,
  and the modification and change times of the files with those it noted
  last, and reads the files only when something differs. That takes a few
  calls for each file instead of reading it, which saves most of a poll's
  CPU when the files are a few large ones, as in the benchmark's set, and
  little when they are many small body files; startup and each check that
  reads pay for both. While nothing changes, smock still makes the one
  call for each file and directory every second, and the others every
  10 s: about 15 calls a second for the benchmark's set and a certificate
  pair, and for a directory of a thousand body files about 1,500, which
  keep 1% to 2% of an Apple M1 core busy while smock is idle. While a
  change settles, it compares every 250 ms. File times are coarse, so the
  polls of the 2 s after a change compare and read the files too, also
  right after startup when the files were written less than 2 s before.
  After a read that met a problem reading the directory, such as a file
  that cannot be read, each poll reads again while the problem lasts:
  smock reads and hashes every file each second until it is fixed. These
  reads come at the poll, with no quiet period, so they reload nothing.
  When the files differ from those read last, perhaps because one was
  read half written, smock waits for them to settle, as when a poll finds
  a change, and reloads them then. So a change of several files made just
  as such a read begins still gives one reload. A file time ahead of the
  clock is logged as a warning, once. A modification time ahead, as from
  an archive made on a host whose clock ran ahead, changes nothing else;
  a change time ahead, which only a clock set back gives, makes each poll
  read the files until the clock passes it.
- A reload reads and validates every file, builds a whole new definition
  set and swaps it in at once, so no request sees half of a reload.
  Requests already being handled finish with the set they started with,
  body-file bytes included. Until the swap, requests are answered from the
  current set, also while the digest of the new files is computed, however
  large they are. Reading and validating the new files can still delay
  requests for a moment, longer for larger files.
- Ephemeral Stubs survive the swap. A Mock the new set no longer declares is
  gone: its Ephemeral Stubs are dropped, and its Hosts resolve like any
  unknown Host. An [Ephemeral gRPC
  Stub](definition-files/grpc.md#ephemeral-grpc-stubs) answers calls while
  the Mock's new set has its method as a unary method.
- [Variables](definition-files/variables.md#variables) survive the swap.
  Those of a Mock that is gone are dropped with it.
- [Copies of Data buckets](definition-files/data-buckets.md#session-copies)
  survive the swap while their bucket stays as it was. A copy is dropped
  when its Mock is gone, when the new set no longer declares its bucket, or
  when the bucket's initial value or `key` changed. Initial values are
  compared as compact JSON, so moving one between `json` and `jsonFile` is
  no change. A change of `newKey` keeps the copies, since their data stays
  valid.
- [Scenario](definition-files/scenarios.md#scenarios) state survives the
  swap while its name still exists. A Scenario's state, for a Session or for
  requests without one, stays when a Stub of the same Mock still names it
  for that Scenario, in `requires` or in `moveTo`: a Stub in the files, or
  one of that Session's own Ephemeral Stubs. Any other state goes back to
  `Started`. The states of a Mock that is gone are dropped with it. So
  editing a response body leaves tests in progress where they are in their
  flows, and a state that only a test's own Ephemeral Stubs name survives a
  change to the files.
- Renaming a state loses the state of tests in progress. A test whose
  Scenario is in the old state goes back to `Started` in the middle of its
  flow, and its next requests may miss. Rename a state when no test relies
  on it.
- Editing a bucket's initial value, inline or in its `jsonFile`, or its
  `key`, resets every Session's copy of it, those of tests in progress
  included. Their requests read the new initial value from then on, and
  the data they wrote is gone. Edit a bucket when no test relies on its
  data.
- When the new set is invalid, smock keeps serving the current one and
  reports every problem, as `smock check` would, in the Admin API status, in
  a log entry and in the reload metric. Scenario state, Variables and
  copies of Data buckets stay as they are. Fix the files, and the next
  reload swaps the fixed set in.
- When the new set has the digest of the one served, nothing is swapped,
  and Scenario state, Variables and copies of Data buckets stay as they
  are.
- Without `--dir`, there is nothing to watch and nothing is reloaded.

Each definition set has a *definition set digest*: a short content hash of
its Definition files and body files, so that replicas serving the same files
report the same digest. While a ConfigMap update rolls out, the digest in
each replica's status shows which set it serves. The digest is the first 12
hex digits of the SHA-256 of every file, framed one after another: the
Definition files in byte-wise order of their names (relative to the
definitions directory), then the body files in the same order (relative to
the body-file subdirectory). Each file is framed as

- one byte, `D` for a Definition file or `B` for a body file;
- the length of its name in UTF-8 bytes, as an 8-byte big-endian number,
  then the name;
- the length of its contents, as an 8-byte big-endian number, then the
  contents.

Every part carries its length, so two different sets never frame to the
same bytes. Files that are not part of the set, such as `notes.txt` or
`.hidden.json`, do not change the digest.

`GET /v1/status` on the Admin API shows the digest served and the result
of the last reload (`null` until the first one), as
[openapi/admin.json](../openapi/admin.json) defines them:

```json
{
  "digest": "3f1c0a9b2e7d",
  "lastReload": {
    "at": "2026-10-13T09:12:44.317Z",
    "result": "failed",
    "errors": [
      { "file": "users.json", "pointer": "/stubs/0/response/status",
        "message": "must be an integer from 200 to 599" }
    ]
  }
}
```

`result` is `swapped` (the new set is served now), `unchanged` (it had the
digest served) or `failed` (it was invalid; the previous set is still
served). Each reload also writes one log entry: `definitions reloaded` with
`oldDigest`, `newDigest`, `scenarioStatesReset` and `dataBucketsReset`, or
`definitions reload failed` with the digest still served and every error.
`scenarioStatesReset` is the number of Scenario states the reload sent
back to `Started`, 0 when there are none. The states dropped with a
removed Mock are not counted. `dataBucketsReset` is the number of copies
of Data buckets the reload dropped, 0 when there are none, those of a
removed Mock included:

```json
{"time":"2026-10-22T09:00:00.000Z","level":"info","msg":"definitions reloaded","result":"swapped","oldDigest":"3f1c0a9b2e7d","newDigest":"8a41d0c2f5e3","scenarioStatesReset":0,"dataBucketsReset":1}
```

Like every log field, these are a diagnostic aid, and a release may change
them. The Prometheus counter `smock_definition_reloads_total` counts reloads
by `result`. A failed reload does not change readiness: `/readyz` on the
admin port still passes, so one bad commit does not drain every Pod.

## Checking a definitions directory

`smock check <dir>` reads a definitions directory the way `smock serve`
does, so a directory that passes `smock check` loads in `smock serve`, and
the reverse. It prints every problem on its own line, with the file and a
JSON Pointer to the value, and exits with status 1. A valid directory prints
nothing, apart from [warnings](#warnings), and exits with status 0. A
directory that does not exist is an empty definition set, as for `smock
serve`, so it passes too; `smock check` then says on stderr that the
directory does not exist, so that a mistyped path is noticed. Give it the
`--template-env` that `smock serve` gets, with the same variables set, so
that it accepts the same
[templates](definition-files/templates.md#environment-variables), and the
same `--header-size-limit`, which bounds a [gRPC reply's
metadata](grpc/metadata-and-status.md#metadata-size).

```console
$ smock check defs
20-orders.json: /stubs/0/mock: no file declares the Mock "orders"
20-orders.json: /stubs/1/request/path: must start with /
$ echo $?
1
```

`smock check` also checks the rules the Schema cannot express, because they
span the Mocks and files of the set. Among them, Mock names, Stub IDs and
the names of a Mock's Data buckets are unique, no two Mocks claim the same
Host after normalisation, at most one Mock is marked `default`, and every
Stub and Data bucket names a Mock that some file declares. A duplicate is
reported where it occurs the second time, in file-name order, and the
message names the first. It also compiles every
[pattern](definition-files/matching.md#pattern-conditions), which the Schema
accepts as any string, and rejects two names in one response's `headers`
that differ only in case, since the Schema compares names exactly. It
rejects a key repeated within one JSON object, as YAML files reject it: JSON
parsers disagree on which of the two values counts, and the Schema sees only
one of them. It checks the [operators in a `json`
condition](definition-files/matching.md#operators-in-json-conditions), where
the Schema accepts any JSON.

In CI, run it as a step that fails the build:

```yaml
- run: smock check defs
```

### Warnings

For a valid directory, `smock check` also warns about four things that
do not stop the directory from loading: a Stub that can never match, a
Stub that requires a state that no Stub moves to, an HTTP Stub whose path
looks like a gRPC method that its Mock's set lacks, and a gRPC reply whose
metadata some clients refuse. Each warning is
one line, marked `warning:`, with the file and a JSON Pointer. Warnings do
not change the exit status:

```console
$ smock check defs
users.json: /stubs/1: warning: the Stub "user-1" can never match: the Stub "any-user" at users.json: /stubs/0 is tried first and matches every request this one would
payments.yaml: /stubs/2/scenario/requires: warning: the Stub "order-paid" requires the state "Payed" of the Scenario "checkout", but no Stub in the Definition files moves "checkout" to "Payed"; only the Admin API or an Ephemeral Stub can
$ echo $?
0
```

#### A Stub that can never match

A Stub can never match when an earlier Stub of the same Mock always matches
first. The warning points at that Stub and names the earlier one. Only Stubs
of one kind are compared: a [gRPC Stub](definition-files/grpc.md#grpc-stubs)
and an HTTP Stub never shadow each other, since HTTP requests never match a
gRPC Stub. gRPC Stubs' `json` conditions are compared as they are
[normalised](definition-files/grpc.md#grpc-stub-conditions), so `{user_id:
42, status: 1}` and `{userId: 42, status: ACTIVE}` are the same condition.

"Earlier" means earlier in the order Stubs are
[tried](definition-files/matching.md#which-stub-answers). A Stub `s` is
shadowed by an earlier Stub `t` when `t` has a subset of `s`'s conditions:

- `t` has no method, or the same method as `s`;
- `t` has no path, the same exact path as `s`, or a pattern that matches
  `s`'s exact path;
- each of `t`'s query, header, cookie and body conditions is also in `s`,
  written the same way (header names in any case), operators included;
  each field of `t`'s `form` condition and each path of its `xml`
  condition is in `s`'s, in any order, with the same condition;
- `t` has no `requires`, or `s` names the same
  [Scenario](definition-files/scenarios.md#scenarios) with the same
  `requires`. `moveTo` plays no part, since it does not change whether a
  Stub matches.

So the pending and paid Stubs of the [Scenario
example](definition-files/scenarios.md#an-example) do not shadow each other:
they have the same request, but require different states. Two Stubs with the
same request that require the same state are still reported.

A [CRUD Stub](definition-files/crud-stubs.md#crud-stubs) matches by its
method and path alone, in every state. smock warns in three cases:

- an earlier CRUD Stub shadows a Stub whose `method` and exact `path` it
  serves, whatever that Stub's other conditions or `requires`. This catches
  an [override](definition-files/crud-stubs.md#order-and-overrides) placed
  after the CRUD Stub instead of before it;
- an earlier CRUD Stub shadows a CRUD Stub with the same `path`;
- an earlier Stub shadows a CRUD Stub only when it has no request
  conditions and no `requires`.

A partial overlap gets no warning. A Stub with no `method` after a CRUD
Stub still matches the methods the CRUD Stub does not serve, such as
`HEAD`. A Stub with a `path` pattern is not compared with a CRUD Stub's
paths.

smock does not compare two patterns, or a pattern or `json` condition with
another condition, and does not reason about operators: a value and its
`$not` are not seen to exclude each other. It warns only when the
shadowing is certain, so a warning is never a false alarm, but some Stubs
that can never match are not reported.

#### A state that no Stub moves to

A Scenario has no declaration, so a typo in a state name loads without a
problem: `requires: Payed` names a state that no Stub reaches. smock warns
when a Stub requires a state other than `Started` that no Stub of the same
Mock and Scenario moves to with `moveTo`, in any Definition file. The
warning points at the `requires` value.

The warning states a fact about the files. It does not say the Stub can
never match, because an Ephemeral Stub or the Admin API can still move the
Scenario to that state, for example for a test that starts in the middle
of a flow.

- A state that only `moveTo` names is not reported. A last state, after
  which Stubs without a clause answer, is a normal design.
- Ephemeral Stubs are never checked, and their `moveTo` does not count:
  `smock check` reads only the Definition files.

#### A path that looks like a gRPC method

A Stub whose exact `path` names a method of its Mock's [Descriptor
set](definition-files/grpc.md#descriptor-sets) is a [gRPC
Stub](definition-files/grpc.md#grpc-stubs). So a typo in the path, such as
`/helloworld.Greeter/SayHelo`, leaves an HTTP Stub, which gRPC calls never
reach. Without `status`, it fails to load, since an HTTP Stub's response
needs one. With `status`, it loads, and smock warns when the Stub's Mock has
a set and the path has the form of a gRPC method, `/package.Service/Method`,
but names no method of the set. The warning points at the `path`:

```text
greeter.yaml: /stubs/1/request/path: warning: the Stub "hello-typo" is an HTTP Stub that gRPC calls never reach: its path has the form of a gRPC method, /package.Service/Method, but the Mock's Descriptor set has no method helloworld.Greeter/SayHelo
```

- The form is `/`, two or more names joined by `.`, `/` and one name,
  each name a letter or `_` followed by letters, digits and `_`. So
  `/users/1`, `/Greeter/SayHello` and `/v1.2/items` get no warning.
- A path pattern, a CRUD Stub and a Stub of a Mock without a set get none.
- The warning states a fact. The Stub may be an HTTP Stub on purpose, for
  clients that call its path over HTTP/1.1.

#### gRPC reply metadata over 8 KiB

gRPC lets a client limit each block of a reply's metadata, its HEADERS and
its trailers, or its Trailers-Only block, to 8 KiB. smock warns about a
[gRPC Stub](definition-files/grpc.md#grpc-stubs)'s static reply with a
larger block, counted as the load counts it against `--header-size-limit`
([gRPC reply metadata](definition-files/grpc.md#grpc-reply-metadata)). The
warning points at the reply:

```text
greeter.yaml: /stubs/0/response: warning: the reply's Trailers-Only block would take 9466 bytes, over 8192, the size gRPC lets a client limit each block of a reply's metadata to: such a client fails the call
```

A templated reply gets no warning, since its size is known only once
rendered.

## Writing Definition files in YAML

Definition files can be YAML (`.yaml` or `.yml`), mixed with JSON files
in one directory. A YAML file means exactly what the equivalent JSON file
means. `defs/users.yaml` is the same as the `defs/users.json` of the
[README's quick start](../README.md#run):

```yaml
mocks:
  - name: users
stubs:
  - id: get-user
    mock: users
    request: { method: GET, path: /users/1 }
    response:
      status: 200
      headers:
        Content-Type: application/json
      body: '{"id":1,"name":"Alice"}'
```

To keep that meaning the same in every YAML version and tool, smock accepts
only a safe subset of YAML (`yaml/`):

- Block and flow collections, plain and quoted scalars, `|` and `>` block
  scalars with their chomping indicators, comments, and one document.
- Plain `true`, `false`, `null` and JSON-syntax numbers are typed; quoted
  scalars are always strings. Any other plain scalar that YAML 1.1 or 1.2
  would type, such as `yes`, `on`, `~`, `True`, `0x1F`, `007`, `1_000`,
  `.inf` or `2001-12-14`, is rejected with "quote this value". Every other
  plain scalar is a string.
- Anchors, aliases, tags, merge keys, duplicate keys, multiple documents
  and tabs in indentation are rejected. A mapping or a sequence that
  starts on the line of a `-` is indented by the `-` and the white space
  after it, so a tab there is rejected too. Before a scalar or a flow
  collection, a tab after `-` only separates them.
- Some valid YAML is rejected too, on purpose: a file with no document,
  such as an empty file or one of comments only; a key that is a
  collection, such as `[a, b]: 1`; a `key: value` pair in a flow sequence
  without braces, such as `[a: 1]` (write `[{a: 1}]`); a key of a flow
  mapping written over several lines, such as a plain key whose `:` is on
  the next line; a tab in the white space at the start of a line, even
  where YAML would read it as a separator rather than as indentation; and
  a line of white space whose tab comes before a block scalar's
  indentation, with nothing after it but empty lines, comments and the
  `...` that may end the document, as when `body: |` and `  hello` are
  followed by a last line of a space and a tab. YAML reads that line as a
  comment after the document; smock rejects it as a tab in indentation,
  as libyaml and PyYAML do.

A JSON file with a key repeated in one object is rejected too, at the later
key: JSON parsers disagree on which of the two values counts.

The YAML parser also holds to these rules:

- An empty value, as in `body:` with nothing after it, is rejected: write
  `null`, or `""` for an empty string. A key with nothing written, as in
  `: value`, is rejected as an empty value is, with "a key must not be
  empty".
- A key that repeats in a mapping is rejected at the later key, with
  "duplicate key". `id:` and `"id":` are the same key.
- The members of a mapping are read in the order they are written.
- A `#` starts a comment only at the start of a line or after a space or
  a tab, as YAML says. Right after other text of a plain value, it is part
  of the value, as in `path: /a#b`; anywhere else, such as right after a
  quoted value or a flow collection, as in `body: "x"# note`, it is
  rejected with "a comment needs a space before its #".
- A byte order mark (U+FEFF) may start the file, and is dropped there.
  Anywhere else, it is text inside a quoted value, as YAML says, and the
  file is rejected when one is outside quotes. A second mark at the start
  of the file, and a mark in a plain value or key, a comment or a block
  scalar, are rejected with "U+FEFF is a byte order mark; write it as an
  escape in a double-quoted value".
- A block scalar whose last line ends the file without a line break gets
  no line break added, as YAML 1.2.2 says (section 8.1.1.2), with each
  chomping indicator: a file that ends with `body: |` and then `  hello`,
  with no line break after it, reads `body` as `"hello"`.

Every problem is reported with the file and the JSON Pointer of the value,
such as `users.yaml: /stubs/0/request/method: "on" may be read as a boolean;
quote this value`.

## Editor support

Editors that understand JSON Schema validate and complete Definition files
once they are associated with the Schema. In Visual Studio Code, add this to
the workspace's `.vscode/settings.json`, with the path of your definitions
directory:

```json
{
  "json.schemas": [
    {
      "fileMatch": ["defs/*.json"],
      "url": "https://hirunefu.github.io/smock/schema/v1/definitions.json"
    }
  ]
}
```

For YAML Definition files, the YAML extension by Red Hat (which runs
yaml-language-server) takes the Schema the same way, in `yaml.schemas`:

```json
{
  "yaml.schemas": {
    "https://hirunefu.github.io/smock/schema/v1/definitions.json": [
      "defs/*.yaml",
      "defs/*.yml"
    ]
  }
}
```

Do not add a `$schema` field to the files themselves: smock rejects fields
the Schema does not define. In a YAML file, a comment can name the Schema
instead, since comments are not fields:

```yaml
# yaml-language-server: $schema=https://hirunefu.github.io/smock/schema/v1/definitions.json
mocks:
  - name: users
stubs:
  - id: get-user
    mock: users
    request: { method: GET, path: /users/1 }
    response:
      status: 200
      body: '{"id":1,"name":"Alice"}'
```

## Writing Definition files in another configuration language

smock reads only JSON and YAML, but any configuration language that exports
JSON works. This Jsonnet file,
[`docs/examples/users.jsonnet`](examples/users.jsonnet), writes one Stub per
user with a function:

```jsonnet
local getUser(id, name) = {
  id: 'get-user-%d' % id,
  mock: 'users',
  request: { method: 'GET', path: '/users/%d' % id },
  response: {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: std.manifestJsonMinified({ id: id, name: name }),
  },
};

{
  version: 1,
  mocks: [{ name: 'users' }],
  stubs: [getUser(1, 'Alice'), getUser(2, 'Bob'), getUser(3, 'Carol')],
}
```

Export it into the definitions directory, then check the result:

```sh
jsonnet users.jsonnet -o defs/users.json
smock check defs
```

The exported file is committed as the fixture
[`schema/v1/fixtures/valid/users-from-jsonnet.json`](../schema/v1/fixtures/valid/users-from-jsonnet.json),
so CI checks it with the rest. CUE (`cue export --out json`) and Pkl (`pkl
eval -f json`) work the same way.

An OpenAPI document is turned into a Definition file by smock itself:
`smock import-openapi` writes a Stub for each documented response of each
operation, as [Importing OpenAPI](importing-openapi.md) explains.
