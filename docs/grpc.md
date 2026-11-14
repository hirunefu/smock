# gRPC

A Mock can stand in for a gRPC service. It names the service's
Descriptor set, the compiled form of its `.proto` files, and smock reads
and checks the set when it loads the Definition files. Its gRPC Stubs then
answer unary calls, on the plain port over h2c. This guide shows a first
call, says how a call reaches a Stub and how smock answers it, and how to
build a set that smock reads. The
[Definition-file reference](definition-files.md#grpc) describes the
Mock's `grpc` field and gRPC Stubs.

## Contents

- [Quick start](#quick-start)
- [How smock serves a call](#how-smock-serves-a-call)
  - [The call the Stubs see](#the-call-the-stubs-see)
  - [The reply](#the-reply)
  - [The Journal and the metrics](#the-journal-and-the-metrics)
- [Calls smock does not serve yet](#calls-smock-does-not-serve-yet)
- [Building a set](#building-a-set)
  - [Self-contained sets](#self-contained-sets)
  - [What smock checks](#what-smock-checks)
  - [What smock keeps](#what-smock-keeps)
  - [One set per Mock](#one-set-per-mock)
  - [Memory](#memory)

## Quick start

Build the Descriptor set of gRPC's
[helloworld.proto](https://github.com/grpc/grpc/blob/master/examples/protos/helloworld.proto)
into the body-file subdirectory of a definitions directory:

```sh
mkdir -p defs/files
protoc --include_imports -o defs/files/greeter.binpb helloworld.proto
```

Write a Mock that names the set, and a gRPC Stub on the method `SayHello`,
in `defs/greeter.yaml`:

```yaml
mocks:
  - name: greeter
    grpc:
      descriptorSet: greeter.binpb
stubs:
  - id: hello
    mock: greeter
    request:
      path: /helloworld.Greeter/SayHello
      body: { json: { name: Tom } }
    response:
      json: { message: Hello Tom }
```

Serve it, and call the method over h2c on the plain port, here with
[grpcurl](https://github.com/fullstorydev/grpcurl), which reads the
method's types from the same set:

```sh
SMOCK_ADMIN_TOKEN=change-me smock serve --dir defs
grpcurl -plaintext -protoset defs/files/greeter.binpb \
  -d '{"name": "Tom"}' localhost:8080 helloworld.Greeter/SayHello
```

```json
{
  "message": "Hello Tom"
}
```

The Journal records the call, with the request message as JSON:

```sh
curl -H "Authorization: Bearer change-me" -d '{}' localhost:9090/v1/journal/query
```

Its entry shows `POST`, the target `/helloworld.Greeter/SayHello`, the
version `HTTP/2`, grpcurl's metadata as headers, the body
`{"name":"Tom"}`, the status 200 and the gRPC status `OK`. With
`{"name": "Ann"}`, which the Stub's condition does not meet, grpcurl
reports `Code: Internal` and `Message: no Stub matched`
([Calls smock does not serve yet](#calls-smock-does-not-serve-yet)).

## How smock serves a call

An HTTP/2 request on the plain port whose `content-type` is
`application/grpc` is a gRPC call. Every other request, an HTTP/1.1
request with that content type included, is an HTTP request, which the
Mock's HTTP Stubs answer as before.

When the call's request has ended, smock:

1. takes the call's one message from its body;
2. finds the call's Mock, the Mock whose Hosts include the call's
   `:authority`, or else the Default Mock;
3. finds the method that the call's `:path`, such as
   `/helloworld.Greeter/SayHello`, names in the Mock's set;
4. decodes the message into JSON with the method's input type;
5. matches the call against the Mock's gRPC Stubs on that method;
6. encodes the reply with the method's output type, and sends it.

Steps 2 to 6 use one version of the Definition files, so a reload never
decodes a call with one version of a set and answers it with another.

### The call the Stubs see

A gRPC Stub sees a call as a request:

- the method is `POST`, and the path is the call's `:path`;
- the headers are the call's metadata, every field, `content-type` and
  `te` included;
- the body is the request message as compact JSON, with its fields in
  field-number order, each under its JSON name, and each field the message
  leaves out at its default, such as `""`, `false` or `0`. A field's JSON
  name is its name in lowerCamelCase, such as `inStock` for `in_stock`,
  unless the `.proto` file gives it a `json_name`. So the message
  `name: "Tom"` is `{"name":"Tom"}`.

A call is matched only against the gRPC Stubs on its method, in the order
Stubs are tried, never against an HTTP Stub, even one whose conditions it
meets. A `json` body condition matches the decoded message, as it matches
a JSON body:

```yaml
request:
  path: /helloworld.Greeter/SayHello
  body: { json: { name: Tom } }
```

For now, smock decodes messages whose fields are all singular `string`,
`bool` and `int32` fields outside any oneof. It answers with replies of
every proto3 type but the well-known types
([The reply](#the-reply)). The
[Definition-file reference](definition-files.md#grpc-stubs) lists what a
gRPC Stub cannot hold yet.

### The reply

A gRPC Stub's reply is `json`, the reply message, read as ProtoJSON reads
JSON, so a reply that grpcurl or another tool printed can be pasted as it
is:

| Field | In `json` |
|---|---|
| Any field | Its name as the `.proto` file spells it, such as `user_id`, or its JSON name, such as `userId`. Giving both in one object is a problem. |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | A number or a string, in its type's range: `7` or `"7"`. An exponent or a fraction of zeros is fine, such as `1e3` or `"100.0"`. |
| `int64`, `sint64`, `sfixed64`, `uint64`, `fixed64` | The same, exact at any size: `"9223372036854775807"`, or the number, whose digits smock keeps. |
| `float`, `double` | A number or a string, or `"NaN"`, `"Infinity"` or `"-Infinity"`. A `float` is rounded to the nearest 32-bit float, and one beyond its range is a problem. |
| `bool` | `true` or `false`. |
| `string` | A string. |
| `bytes` | A string in base64, standard or URL-safe, with or without its padding. |
| An enum | The name of a value, such as `ACTIVE`, or a number, which may name no value, as an open enum allows. |
| A message | An object. |
| A repeated field | An array. `null` in it is a problem. |
| A map | An object whose keys are the map's keys as strings: integers in decimal, such as `"-1"`, and `"true"` and `"false"`. A `null` value is a problem. |
| A oneof | One of its members. Two members in one object are a problem, but a member that is `null` does not count. |

`null` leaves a field unset. A key that names no field is a problem. A
Stub without `json` answers an empty message, with every field at its
default.

The reply's output type may be any proto3 message, with any of these
fields, but for the well-known types, such as `google.protobuf.Timestamp`,
which smock does not serve yet: a Stub on a method whose output type is
one, or reaches one through its fields, is a problem at its `path`, as is
one whose output type reaches a type of a proto2 or an editions file.

A reply without `template` is read and encoded once, when the files load.
A reply that is not a message of the output type is a problem at the JSON
Pointer of its first value at fault, which `smock check` reports:

```text
replies.yaml: /stubs/0/response/json/tags/1: cannot be null: it is an element of the repeated field tags of replies.User
```

A reply with `template: true` is rendered as JSON, its values escaped as
in any `json` template, then read and encoded on each call. One that is
not a message of the output type gets Trailers-Only INTERNAL with the
message `template failed`, and the call's Journal entry says why in
`templateError`, at the JSON Pointer of the value at fault within the
Stub:

```json
{
  "at": "/response/json/userId",
  "message": "must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of replies.User has the type int64"
}
```

smock encodes the reply as protoc encodes it: fields in field-number
order; a field without presence left out at its default, while a message
field, a member of a oneof and a proto3 `optional` field are written
whenever they are set; repeated scalars packed, unless the field says
`packed = false`; and map entries sorted by key, each with its key and
its value. It sends what a gRPC server sends:

- HEADERS with `:status` 200, `content-type: application/grpc`,
  `smock-mock` when the Default Mock answered, and `date`;
- one DATA frame with the reply message, framed;
- trailers with `grpc-status: 0`, which end the stream.

A reply larger than the client's flow-control windows goes out as the
client widens them, and the trailers follow it.

### The Journal and the metrics

The Journal records each call that reaches the Stubs, matched or not. Its
entry shows the method `POST`, the call's `:path` as its target, the
version `HTTP/2`, the metadata as headers, and the request message as JSON
as its body. The body's `size` counts the octets the call's DATA frames
brought, as received, and `truncated` says whether the JSON was cut at
`--journal-body-limit`.

The entry's `grpcStatus` is the name of the gRPC status the call got:
`OK` for a reply, or the status smock answered with instead, such as
`INTERNAL`. Its `status` stays the HTTP status, 200 for a reply, as gRPC
sends it: a client learns of an error from `grpc-status`, not from
`:status`. The entry of an HTTP request has no `grpcStatus`.

Journal queries, verification and the unmatched list take calls as they
take HTTP requests. A filter gives the Mock, the method `POST`, the path
that names the gRPC method, and metadata as headers:

```json
{
  "filter": {
    "mock": "greeter",
    "method": "POST",
    "path": "/helloworld.Greeter/SayHello",
    "headers": { "x-tenant": "acme" }
  }
}
```

The request metrics count a call that a Stub answered under its Mock and
Stub, as they count an HTTP request, and a call that no Stub matched as
an unmatched request of its Mock.

## Calls smock does not serve yet

smock answers the calls it does not serve yet with Trailers-Only: one
HEADERS block that ends the stream, with `:status` 200,
`content-type: application/grpc`, `grpc-status: 13` (INTERNAL) and a fixed
`grpc-message`. A gRPC client reports INTERNAL with that message.

These calls never reach the Stubs. They are not in the Journal, and the
request metrics count them as rejected requests, with `mock=""` and
`stub=""`:

| The call | `grpc-message` |
|---|---|
| Its method is not `POST` | `the method must be POST` |
| Its body is not one uncompressed message | `the request is not one uncompressed message` |
| No Mock lists its Host, and there is no Default Mock | `no Mock for this Host` |
| Its Mock has no set | `the Mock has no Descriptor set` |
| Its `:path` names no method of the set | `unknown method` |
| Its method streams | `streaming methods are not served yet` |
| Its message does not decode, or its type has a field that smock does not decode yet | `the request message cannot be decoded` |

These calls reach the Stubs. The Journal records each with the
`grpcStatus` `INTERNAL`, and with the HTTP status planned for it: the
Mock's `noMatch` status for an unmatched call, 500 or 507 for smock's own
failures, and 200 for a rendered reply that does not fit the output type,
whose `templateError` says why:

| The call | `grpc-message` |
|---|---|
| No gRPC Stub on its method matches it | `no Stub matched` |
| The Stub's reply, a `variables` value or a `dataWrites` value fails to render, or the rendered reply does not fit the output type | `template failed` |
| A write of the Stub's `dataWrites` cannot be applied | `data write failed` |
| The Stub's writes do not fit the bound on per-Session state | `state limit reached` |

An unmatched call is in the Journal with its Near miss, chosen among the
gRPC Stubs on its method, and in the unmatched list. The status and
headers of the Mock's `noMatch` never reach the client.

## Building a set

smock reads no `.proto` file and runs no protoc. It reads a Descriptor
set: a FileDescriptorSet in protobuf's binary encoding, which buf and
protoc write. Build it into the body-file subdirectory of your Definition
files, `files/` by default:

```sh
buf build -o defs/files/greeter.binpb
protoc --include_imports -o defs/files/greeter.binpb helloworld.proto
```

Then name it from the Mock:

```yaml
mocks:
  - name: greeter
    hosts: [greeter.svc]
    grpc:
      descriptorSet: greeter.binpb
```

smock reads the set with the Definition files: `smock check` reads it, and
so do startup and each reload. A reload swaps the set in together with the
files, and a change to the set reloads them.

### Self-contained sets

A set must hold every file that its files import, the well-known types
such as `google/protobuf/timestamp.proto` included. `buf build` puts them
in by default. protoc puts them in only with `--include_imports`. Without
it, the set lacks the files that yours import, and `smock check` says
which:

```text
greeter.json: /mocks/0/grpc/descriptorSet: "orders.binpb": orders.proto imports common.proto, which is not in the set; build the set with protoc --include_imports, or with buf build
```

### What smock checks

Each problem with a set is a problem at the JSON Pointer of
`descriptorSet`, reported by `smock check`, at startup and on a reload.
A reload with a problem keeps serving the whole current definition set.
smock refuses a set when:

- the file is missing, or does not decode as a FileDescriptorSet;
- a file is in the set more than once;
- a file imports a file that is not in the set;
- a full name is defined twice, such as a message `shop.Order` in two
  files. An enum value's full name is in the scope of its enum's package
  or message, as protobuf scopes it, so two enums of one package cannot
  share a value name;
- a message uses a field number twice, or a field is in a oneof that its
  message does not have;
- a type that a field, a method or an extension names is not defined in
  the set;
- an extension's number is not one that its message declares for
  extensions, or is taken by another extension of the message;
- messages nest deeper than 100, or the full names of the set take more
  than 16 MiB. No set built from real `.proto` files comes near either.

buf and protoc never write a set with the other problems, but a set put
together by hand, or joined from two sets, can have them. smock checks
types only when every import is in the set and every name is defined
once, so a missing import gives one problem, not one for each type the
missing file defines.

### What smock keeps

smock keeps what it needs of each file: its name, package, syntax and
imports; its messages, nested ones included, with their fields, oneofs,
map entries and extension ranges; its enums and their values, aliases
included; its extensions and groups; and its services and methods.

It drops the rest, so it costs nothing:

- source info, the comments and positions that `buf build` keeps by
  default and that `protoc --include_source_info` adds;
- options, custom options included, except the three that change how
  messages are encoded: `map_entry`, `packed` and
  `message_set_wire_format`;
- fields that FileDescriptorSet does not define, such as the extensions
  that a Buf image adds to each file.

So a set built with `buf build -o` and its defaults, which is a Buf image
with source info, loads as it is. Files written in proto2, in proto3 or in
an edition all load.

### One set per Mock

Each Mock names its own set, so two Mocks can hold two versions of one
package, to stand in for two versions of one service:

```yaml
mocks:
  - name: greeter-v1
    hosts: [v1.greeter.svc]
    grpc:
      descriptorSet: v1/greeter.binpb
  - name: greeter-v2
    hosts: [v2.greeter.svc]
    grpc:
      descriptorSet: v2/greeter.binpb
```

A Mock without `grpc` holds no set, and costs nothing more.

### Memory

smock holds each set decoded, with the definition set it belongs to, so
every replica holds it, for as long as it serves those Definition files.
A large set costs memory in each one. For example, a set of 4.8 MB, with
5,000 messages and 100,000 fields, takes about 40 MiB once loaded, and
about 0.15 s to load. Source info costs nothing once loaded, since smock
drops it.

To keep a set small, build it from the files of the services your Mocks
stand in for, not from every file of a large repository: give protoc
only those files, or `buf build` their paths with `--path`.
