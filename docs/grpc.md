# gRPC

A Mock can stand in for a gRPC service. It names the service's
Descriptor set, the compiled form of its `.proto` files, and smock reads
and checks the set when it loads the Definition files. Its gRPC Stubs then
answer unary calls, on the plain port over h2c and on the TLS port over
h2. This guide shows a first call, says which requests are gRPC calls, how
a call reaches a Stub and how smock answers it, and how to build a set
that smock reads. The
[Definition-file reference](definition-files.md#grpc) describes the
Mock's `grpc` field and gRPC Stubs.

## Contents

- [Quick start](#quick-start)
- [Ports and detection](#ports-and-detection)
  - [Other subtypes](#other-subtypes)
  - [Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)
- [How smock serves a call](#how-smock-serves-a-call)
  - [The call's Mock](#the-calls-mock)
  - [Reloads](#reloads)
  - [The call the Stubs see](#the-call-the-stubs-see)
  - [The request message as JSON](#the-request-message-as-json)
  - [The reply](#the-reply)
  - [The Journal and the metrics](#the-journal-and-the-metrics)
- [Unmatched calls](#unmatched-calls)
  - [Calls answered from their HEADERS](#calls-answered-from-their-headers)
  - [The Near miss trailer](#the-near-miss-trailer)
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

The same call goes to the TLS port over h2. Leave out `-plaintext`, and
add `-insecure` while smock serves its self-signed certificate:

```sh
grpcurl -insecure -protoset defs/files/greeter.binpb \
  -d '{"name": "Tom"}' localhost:8443 helloworld.Greeter/SayHello
```

The Journal records the call, with the request message as JSON:

```sh
curl -H "Authorization: Bearer change-me" -d '{}' localhost:9090/v1/journal/query
```

Its entry shows `POST`, the target `/helloworld.Greeter/SayHello`, the
version `HTTP/2`, grpcurl's metadata as headers, the body
`{"name":"Tom"}`, the status 200 and the gRPC status `OK`. With
`{"name": "Ann"}`, which the Stub's condition does not meet, grpcurl
reports `Code: Unimplemented` and `Message: no Stub matched`, and the
Journal records the call as unmatched
([Unmatched calls](#unmatched-calls)).

## Ports and detection

smock serves gRPC on the ports that serve HTTP, beside HTTP. gRPC has no
port of its own:

- the plain port, over h2c: HTTP/2 without TLS, which grpcurl's
  `-plaintext` and a channel without credentials send;
- the TLS port, over h2: ALPN chooses HTTP/2 when the client offers `h2`,
  as gRPC clients do ([h2 on the TLS port](http2.md#h2-on-the-tls-port)).

`--tls-http2 off` also turns off gRPC over TLS. The TLS port then offers
`http/1.1` alone, so a gRPC client, which offers only `h2`, fails the
handshake with the `no_application_protocol` alert: grpcurl reports
`remote error: tls: no application protocol`. The plain port still serves
gRPC. The admin port never serves gRPC: it serves HTTP/1.1 only.

An HTTP/2 request is a gRPC call when its `content-type` is
`application/grpc`, alone or followed by `+` or `;`. The text after `+`,
up to any `;`, is the call's subtype. It names how the call's messages
are encoded, and no subtype means protobuf:

| `content-type` | The request |
|---|---|
| `application/grpc`, `application/grpc;v=1` | a gRPC call that smock serves |
| `application/grpc+proto`, `application/grpc+proto;v=1` | a gRPC call that smock serves |
| `application/grpc+json`, or any other subtype | a gRPC call that smock refuses ([Other subtypes](#other-subtypes)) |
| any other, such as `application/grpc-web` or `application/json`, or none | an HTTP request ([Requests that are not gRPC calls](#requests-that-are-not-grpc-calls)) |

smock compares the content type as sent, in its case, as grpc-go does.

smock's HTTP/2 checks of a request come first, whatever its content type
([Requests smock refuses](http2.md#requests-smock-refuses)). A request that
HTTP/1.1's rules refuse gets 400, and a header list over
`--header-size-limit` gets 431, with no gRPC status. A gRPC client reports
400 as INTERNAL and 431 as UNKNOWN, as gRPC reads answers that are not
gRPC.

### Other subtypes

smock encodes messages with protobuf only. A call with another subtype,
such as `application/grpc+json`, gets UNIMPLEMENTED as soon as its HEADERS
arrive. smock sends it as Trailers-Only: one HEADERS block that ends the
stream, with `:status` 200, `content-type: application/grpc`,
`grpc-status: 12` and the fixed `grpc-message`
`only the proto content subtype is served`. When the client is still
sending its request, RST_STREAM `NO_ERROR` follows and tells it to stop.

The call never reaches the Stubs. It is not in the Journal, and the
request metrics count it as a rejected request, with `mock=""` and
`stub=""`. A call whose method is not `POST` gets that method's answer
instead ([Calls smock does not serve yet](#calls-smock-does-not-serve-yet)).

### Requests that are not gRPC calls

Every other request is an HTTP request. The Mock's HTTP Stubs answer it,
or its `noMatch` answer when none matches, as before:

- an HTTP/2 request with another content type, gRPC-Web's
  `application/grpc-web` included, or with none;
- every HTTP/1.1 request, one with `content-type: application/grpc`
  included. gRPC needs HTTP/2's trailers, so smock serves no gRPC over
  HTTP/1.1.

Such a request never matches a gRPC Stub, even on the path of a gRPC
method.

## How smock serves a call

smock tells a gRPC call by its content type
([Ports and detection](#ports-and-detection)). When the call's HEADERS
arrive, smock finds the call's Mock
([The call's Mock](#the-calls-mock)) and the method that the call's
`:path`, such as `/helloworld.Greeter/SayHello`, names in the Mock's set.
A call that cannot reach a gRPC Stub, since there is no such Mock, set or
unary method, is answered at once, without waiting for its message
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).

When the call's request has ended, smock:

1. finds the call's Mock and its method again, from the Definition files
   it serves then;
2. takes the call's one message from its body;
3. decodes the message into JSON with the method's input type;
4. matches the call against the Mock's gRPC Stubs on that method;
5. encodes the reply with the method's output type, and sends it.

### The call's Mock

A call's `:authority` is its Host, and chooses its Mock, as it does for
any HTTP/2 request ([What a Stub sees](http2.md#what-a-stub-sees)): the
Mock whose `hosts` include it. grpcurl's `-authority` sets it, and so does
the target a gRPC channel is made for. When no Mock lists the Host, the
Default Mock answers the call, with its own set, and the answer carries
`smock-mock` with the Mock's name and `via=default`, as on HTTP. With
neither, the call gets UNIMPLEMENTED `no Mock for this Host`.

Each Mock decodes and answers its calls with its own set. So two Mocks
whose sets hold two versions of one package each serve their own version
([One set per Mock](#one-set-per-mock)):

```yaml
mocks:
  - name: greeter-v1
    default: true
    grpc:
      descriptorSet: v1/greeter.binpb
  - name: greeter-v2
    hosts: [v2.greeter.svc]
    grpc:
      descriptorSet: v2/greeter.binpb
```

A call with `-authority v2.greeter.svc` is decoded and answered with
version 2. A call to any other Host is decoded and answered with version
1, by the Default Mock.

### Reloads

A changed set is reloaded with the Definition files, in one swap
([Building a set](#building-a-set)). A call is decoded, matched and
answered with the set served when its request ends. Steps 1 to 5 above
run with nothing in between, so a reload never decodes a call with one
version of a set and answers it with another.

A reload may come between a call's HEADERS and the end of its request.
The call is looked up again at the end, so it is served with the new
Definition files. When the reload has left the call without a gRPC Stub
to reach, such as a Mock whose set is gone or no longer has the method,
the call gets the answer its HEADERS would get then
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).
A set that fails to load keeps the whole current definition set served.

### The call the Stubs see

A gRPC Stub sees a call as a request:

- the method is `POST`, and the path is the call's `:path`;
- the headers are the call's metadata, every field, `content-type` and
  `te` included;
- the body is the request message as compact JSON, with its fields in
  field-number order, each under its JSON name
  ([The request message as JSON](#the-request-message-as-json)). So the
  message `name: "Tom"` is `{"name":"Tom"}`.

A call is matched only against the gRPC Stubs on its method, in the order
Stubs are tried, never against an HTTP Stub, even one whose conditions it
meets. A call that none of them matches gets UNIMPLEMENTED
([Unmatched calls](#unmatched-calls)). A `json` body condition matches the
decoded message, as it matches a JSON body:

```yaml
request:
  path: /helloworld.Greeter/SayHello
  body: { json: { name: Tom } }
```

The Journal, the Near miss, `bodyText` and templates see the same JSON,
so `${body.name}` in a templated reply reads the message's `name`.

### The request message as JSON

smock prints a request message in one form, the same for every client
that sends it. The fields come in field-number order, each under its JSON
name: its name in lowerCamelCase, such as `inStock` for `in_stock`, unless
the `.proto` file gives it a `json_name`. Each type prints as follows:

| Protobuf | JSON | Example |
|---|---|---|
| `int64`, `uint64`, `sint64`, `fixed64`, `sfixed64` | a number, exact at any size | `9223372036854775807` |
| `int32`, `uint32`, `sint32`, `fixed32`, `sfixed32` | a number | `-5` |
| `double` | a number, as smock's `json` replies write one | `0.1`, `1e+21` |
| `float` | a number, in the shortest form that reads back as the same 32-bit float | `9.99`, not `9.989999771118164` |
| `double` and `float` that are not numbers | the strings `"NaN"`, `"Infinity"` and `"-Infinity"` | `"NaN"` |
| `bool` | `true` or `false` | `true` |
| `string` | a string | `"Kyoto"` |
| `bytes` | a string of standard base64, with padding | `"AAH7/w=="` |
| an enum | the name of its value, the first name when aliases share the number, or the number of a value the enum does not define | `"ACTIVE"`, `7` |
| a message | an object in the same form | `{"city":"Kyoto"}` |

So the message `id: 9223372036854775807 price: 9.99 status: ACTIVE
address { city: "Kyoto" }` is:

```json
{"id":9223372036854775807,"price":9.99,"status":"ACTIVE","note":"","address":{"city":"Kyoto"}}
```

A condition matches it as written: `{price: 9.99, status: ACTIVE}` meets
it, and so does `{id: 9223372036854775807}`, since numbers are compared
exactly.

Which fields print depends on whether a field has presence:

- A field without presence, such as a plain proto3 `string` or `int32`,
  prints even when the message leaves it out, at its default: `0`,
  `false`, `""`, or an enum's value numbered 0. So `{count: 0}` and
  `{name: ""}` match a message that leaves `count` or `name` out.
- A proto3 `optional` field and a message field print only when the
  message holds them, even at their default. So the condition
  `{maybeCount: {$exists: false}}` tells a message that leaves
  `maybe_count` out from one that holds 0.

smock reads a message as protobuf's parsers read it: the last value of a
field wins, two values of a message field are merged, and fields the type
does not have, such as those a newer client sends, are skipped.

For now, smock decodes messages whose fields are singular: repeated
fields, maps, oneofs other than a proto3 `optional` field's, and the
well-known types, such as `google.protobuf.Timestamp`, are not decoded
yet. It answers with replies of every proto3 type but the well-known
types ([The reply](#the-reply)). The
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

The Journal records each call that reaches the Stubs, matched or not, and
each call answered from its HEADERS, with an empty body
([Calls answered from their HEADERS](#calls-answered-from-their-headers)).
Its entry shows the method `POST`, the call's `:path` as its target, the
version `HTTP/2`, the metadata as headers, and the request message as JSON
as its body. The body's `size` counts the octets the call's DATA frames
brought, as received, and `truncated` says whether the JSON was cut at
`--journal-body-limit`.

The entry's `grpcStatus` is the name of the gRPC status the call got:
`OK` for a reply, or the status smock answered with instead, such as
`UNIMPLEMENTED` for an unmatched call, or `INTERNAL`. Its `status` stays
the HTTP status, 200 for a reply and for an unmatched call, as gRPC sends
them: a client learns of an error from `grpc-status`, not from
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

## Unmatched calls

A call that no gRPC Stub on its method matches gets UNIMPLEMENTED, the
status gRPC servers give a method they do not serve. smock sends it as
Trailers-Only: one HEADERS block that ends the stream, with `:status` 200,
`content-type: application/grpc`, `grpc-status: 12` and the fixed
`grpc-message` `no Stub matched`. With the quick start's Stub, a call with
`{"name": "Ann"}` gets:

```text
:status: 200
content-type: application/grpc
grpc-status: 12
grpc-message: no Stub matched
smock-mock: greeter; via=default
smock-near-miss: hello; failed=body
date: Sat, 14 Nov 2026 07:00:00 GMT
```

`smock-mock` is there because the Default Mock answered, as on HTTP. The
message never changes, so a test that checks it stays stable.

The Mock's `noMatch` applies to HTTP requests only. Its status and its
headers never reach a gRPC call.

The Journal records an unmatched call with the HTTP status 200, the
`grpcStatus` `UNIMPLEMENTED`, and its full Near miss: each condition that
the closest Stub failed, with what it expects and what the call sent. The
call is in the unmatched list, `GET /v1/journal/unmatched`, and the
request metrics count it as an unmatched request of its Mock.

### Calls answered from their HEADERS

A call that cannot reach a gRPC Stub gets UNIMPLEMENTED as soon as its
HEADERS arrive, without waiting for its message, so the client does not
wait for a timeout. Each case has its own fixed `grpc-message`:

| The call | `grpc-message` |
|---|---|
| No Mock lists its Host, and there is no Default Mock | `no Mock for this Host` |
| Its Mock has no set | `the Mock has no Descriptor set` |
| Its `:path` is not `/service/method`, or names no method of the set | `unknown method` |
| Its method streams | `streaming methods are not served yet` |

The answer is Trailers-Only, as for a call that no Stub matched. When the
client is still sending its request, RST_STREAM `NO_ERROR` follows the
answer and tells it to stop. So with the quick start's Mock and Stub, a
call to `/helloworld.Greeter/SayGoodbye`, a method that helloworld.proto
lacks, gets:

```text
:status: 200
content-type: application/grpc
grpc-status: 12
grpc-message: unknown method
smock-mock: greeter; via=default
smock-near-miss: hello; failed=path,body
date: Sat, 14 Nov 2026 07:00:00 GMT
```

then RST_STREAM `NO_ERROR` if the call has not ended. A client reports
`Code: Unimplemented` with the message.

The call is still an unmatched call of its Mock. The Journal records it
with an empty body, whose `size` counts the octets that had arrived, and
with its Near miss when it has one. It is in the unmatched list, and the
request metrics count it as unmatched. A call whose Host reaches no Mock
is counted under `mock=""`.

smock looks the call up again when its request ends. A call that a reload
has left without a gRPC Stub to reach by then gets the same answer, then,
with the octets of its message as its body's `size`
([Reloads](#reloads)).

### The Near miss trailer

The Near miss is the gRPC Stub of the call's Mock that failed the fewest
conditions, the one tried first on a tie, as on HTTP
([When no Stub matches](definition-files.md#when-no-stub-matches)). A
Stub on another method fails the `path` condition, so a call to a method
that no Stub is on, or that the set lacks, has a Near miss too. smock
sends it in the `smock-near-miss` field of the answer, in the form of the
HTTP `Smock-Near-Miss` header: the Stub's ID, then the conditions it
failed. With a Stub that requires the metadata `x-tenant: acme`, a call
without it gets:

```text
smock-near-miss: hello; failed=header:x-tenant
```

The field is ASCII only. The Stub ID and the names in it, such as a
metadata name, are percent-encoded where they hold anything other than the
characters of an HTTP token. It never carries what a condition expects or
what the call sent: the Journal entry has those.

A gRPC client reads the field as trailing metadata, as it reads every field
of a Trailers-Only answer. grpcurl prints it with `-v`, among the response
trailers.

A call has no Near miss, and its answer no `smock-near-miss` field, when
its Host reaches no Mock, or its Mock has no gRPC Stub, which a Mock
without a set never has. An HTTP Stub is never a call's Near miss, even one whose
path pattern takes the call's path.

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
| Its message does not parse, or its type has a field that smock does not decode yet | `the request message cannot be decoded` |

A message does not parse, as protobuf's parsers refuse it, when it holds a
proto3 string that is not UTF-8, field number 0 or one above 2^29-1, wire
type 6 or 7, a varint or a length cut short, or messages nested deeper
than 100.

These calls reach the Stubs. The Journal records each with the
`grpcStatus` `INTERNAL`, and with the HTTP status planned for it: 500 or
507 for smock's own failures, and 200 for a rendered reply that does not
fit the output type, whose `templateError` says why:

| The call | `grpc-message` |
|---|---|
| The Stub's reply, a `variables` value or a `dataWrites` value fails to render, or the rendered reply does not fit the output type | `template failed` |
| A write of the Stub's `dataWrites` cannot be applied | `data write failed` |
| The Stub's writes do not fit the bound on per-Session state | `state limit reached` |

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
