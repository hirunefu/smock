# Migrating from Mockoon

This guide turns a Mockoon environment into Definition files for smock.
It is written for Mockoon 9.x environment files, whose `lastMigration` is
33, and its statements about Mockoon were checked against Mockoon 9.9.0,
its documentation and its source from 2026-10-17 to 2026-10-22. It starts
with what smock does not do, so that a reader whose environments depend
on one of those features can stop there. A worked example then
translates one environment step by step, and a reference at the end maps
every part of an environment that has a counterpart:

- The example is in [`examples/from-mockoon/`](examples/from-mockoon/):
  the Mockoon environment `mockoon/users-api.json`, and the definitions
  directory `defs/` that replaces it. `smock check` passes on it, and
  both servers give the answers this guide shows.
- Mockoon's own words (environment, route, response, rule) name
  Mockoon's features. smock's terms, such as Mock and Stub, are
  introduced [below](#how-the-models-differ) and defined in
  [GLOSSARY.md](../GLOSSARY.md).
- Unless a step says otherwise, the commands run in
  `docs/examples/from-mockoon/`, with `mockoon-cli` and `smock` on the
  `PATH`. [Running it where Mockoon ran](#running-it-where-mockoon-ran)
  says where to get smock.
- The guide and its example need smock 0.3.0 or later. The operators
  and the cookie, form and XML conditions that [Rules](#rules) maps came
  in 0.2.0. Data buckets and CRUD Stubs, Variables, `responses`, the
  template roots `cookie` and `env`, the helpers for text, encodings,
  JWTs, dates and arithmetic, `find`, byte ranges and
  `smock import-openapi` came in 0.3.0. An older smock fails to load a
  Definition file that uses one of those fields, roots or helpers, and
  `smock check` names each, as in `/data: is not a known field` or
  `unknown helper "add"`.

## Contents

- [What smock does not do](#what-smock-does-not-do)
- [How the models differ](#how-the-models-differ)
- [A worked example](#a-worked-example)
  - [List the routes Mockoon serves](#list-the-routes-mockoon-serves)
  - [Declare the Mock](#declare-the-mock)
  - [Environments told apart by port](#environments-told-apart-by-port)
  - [One Stub per response](#one-stub-per-response)
  - [Paths and request conditions](#paths-and-request-conditions)
  - [Bodies, headers and templates](#bodies-headers-and-templates)
  - [Latency, CORS and the CRUD route](#latency-cors-and-the-crud-route)
  - [Answers that change between requests](#answers-that-change-between-requests)
  - [The result](#the-result)
- [Behaviour that differs](#behaviour-that-differs)
- [Checking the migration](#checking-the-migration)
- [Running it where Mockoon ran](#running-it-where-mockoon-ran)
- [Mapping reference](#mapping-reference)
  - [Environments and routes](#environments-and-routes)
  - [Rules](#rules)
  - [Responses](#responses)
  - [Template helpers](#template-helpers)
  - [Running and operating](#running-and-operating)

## What smock does not do

These Mockoon features have no counterpart in smock. Where something
covers part of the need, the item says what.

- **Proxy mode and recording.** smock never forwards a request to the
  real service and never records traffic: every answer comes from a
  Stub, and a request that no Stub matches gets a 404. Before switching,
  find the paths that clients reached through the proxy: the Mockoon CLI
  logs each request with `"requestProxied":true` or `false`.
- **Some features of data buckets and CRUD routes.** A data bucket
  becomes a [Data bucket](definition-files.md#data-buckets), and a CRUD
  route a [CRUD Stub](definition-files.md#crud-stubs), as
  [the CRUD route](#latency-cors-and-the-crud-route) of the example and
  [Data buckets](#data-buckets) show. These have no counterpart:
  - templated or generated bucket content: a bucket's initial value is
    static JSON, so save the value that Mockoon generated
    ([Behaviour that differs](#behaviour-that-differs));
  - CRUD routes over a bucket that is not an array of objects with keys,
    such as an object or an array of texts: ordinary Stubs read and write
    such a bucket ([Data buckets](#data-buckets));
  - nested keys, such as a `crudKey` of `data.id`;
  - list operators other than equality, such as `_gt` and `_like`, and
    `search`;
  - `PUT`, `PATCH` and `DELETE` on a whole list: ordinary Stubs with
    `dataWrites` take them ([Data buckets](#data-buckets));
  - writes to a path inside a value, as `setData` takes: a write sets or
    merges a whole bucket, or one item of a bucket with keys.
- **Callbacks.** smock never sends a request of its own. A test that
  relied on a callback sends that request to the callback's URL itself,
  and can check in the Journal that the request that fired it arrived.
- **WebSockets.** smock serves HTTP/1.1 and HTTPS. It can stream
  Server-Sent Events, which only a client written for them reads.
- **Schema validation, multipart bodies and rules on state.** The
  `valid_json_schema` operator has no counterpart, and a multipart body
  can be matched only by a pattern on the whole body. The rule targets
  `global_var`, `data_bucket` and `templating` have none either: a
  condition reads the request, never a Variable or a Data bucket.
  [Rules](#rules) maps the other rules, `invert` and rules on cookies,
  form fields and XML bodies included.
- **Some Handlebars helpers.** smock's templates are not Handlebars.
  [Template helpers](#template-helpers) maps the helpers that have a
  counterpart, among them arithmetic, strings, dates, JWTs, cookies,
  environment variables and global variables. These have none:
  - array literals, local variables (`setVar` and `getVar`), and
    comparisons other than `==` and `!=`, such as `gt` and `lt`;
  - helpers that filter, sort or merge arrays and objects, such as
    `filter`, `sort` and `objectMerge`;
  - `jsonParse`, `someOf`, `objectId`, random dates (`date` and `time`)
    and faker locales;
  - the `status` helper: [`responses`](#random-responses) vary the
    status instead;
  - setting a global variable or a data bucket from inside a template:
    a Stub's `variables` set [Variables](#global-variables), and its
    `dataWrites` write [Data buckets](#data-buckets), instead;
  - local time and time-zone names: Mockoon writes dates in its process's
    time zone, such as `TZ=Asia/Tokyo`, and smock in UTC or at a fixed
    offset, such as `+09:00`. Neither has date locales: month and day
    names are in English;
  - the `MOCKOON_` prefix of environment variables: `--template-env` lists
    each name in full.
- **A port or a path prefix per environment.** One smock serves all its
  Mocks on one plain port and one TLS port, and tells them apart by the
  request's Host.
  [Environments told apart by port](#environments-told-apart-by-port)
  gives the two ways round it.
- **Response limits.** A response's status is from 200 to 599. A body
  file serves one byte range at a time, never `multipart/byteranges`, and
  there are no conditional requests, since smock sends no `ETag` or
  `Last-Modified`. Mockoon has neither, but sends the first of several
  ranges where smock sends the whole body
  ([Behaviour that differs](#behaviour-that-differs)).
- **OpenAPI export, and a GUI.** smock writes no OpenAPI document, and
  Definition files are edited as text. Editors can check them against the
  JSON Schema ([editor support](definition-files.md#editor-support)).
- **Windows and macOS.** smock runs on Linux, on amd64 and arm64, or in a
  Linux container.

An environment that Mockoon imported from an OpenAPI document can be
imported into smock from the same document, with `smock import-openapi`,
instead of being translated by hand.
[Importing OpenAPI](importing-openapi.md) explains the command, and its
[notes for Mockoon users](importing-openapi.md#notes-for-mockoon-users)
say where the result differs from Mockoon's import. Only what was changed
in the environment after the import, such as rules, is then translated
with the steps below.

## How the models differ

A Mockoon environment is a server of its own: a port, a path prefix, and
routes in order, each with responses in order that rules choose between.
smock's model is flatter:

- A *Definition file*, in YAML or JSON, declares *Mocks* and their
  *Stubs*. The files sit in a definitions directory, such as `defs/`,
  with body files in its `files/` subdirectory, and smock reloads them
  when they change.
- A Mock stands in for one service, as an environment does. A request
  reaches a Mock by its Host, not by its port. A lone Mock is the
  *Default Mock*, which also answers requests for Hosts that no Mock
  lists.
- A Stub pairs request conditions with one response, or with several
  `responses` that it picks from at random. Each response of a Mockoon
  route becomes a Stub of its own, whose conditions are the route's
  method and path plus the response's rules, except that the responses of
  a `RANDOM` route share one Stub.
- The first Stub that matches a request answers it. Stubs are tried in
  the order they are declared, unless `priority` reorders them, so the
  order of the routes, and of the responses within each route, carries
  over.
- A *Scenario* is a named state machine within a Mock, which starts in the state
  `Started`. A Stub can require one of its states and move it to
  another, so that the same request gets different answers at different
  points of a flow.
- A *Variable* is a named JSON value that a Stub writes when it matches,
  and that templates read. Like a Scenario's state, it is kept per Mock
  and per Session. Variables stand in for global variables.
- A *Data bucket* is a named JSON value that a Mock declares with its
  initial value, as an environment declares a data bucket. Templates read
  it, and Stubs write it when they match. Each Session reads and writes a
  copy of its own. A *CRUD Stub* serves a bucket of objects with keys as
  a REST resource, as a CRUD route does.
- A response is a template only with `template: true`, and templates
  insert values with `${…}` expressions, not Handlebars.
- A request that no Stub matches gets a 404 whose `Smock-Near-Miss`
  header names the *Near miss*: the Stub that came closest, and the
  conditions it failed.

[docs/definition-files.md](definition-files.md) describes the format in
full.

## A worked example

The environment `users-api`, in
[`mockoon/users-api.json`](examples/from-mockoon/mockoon/users-api.json),
has the prefix `api/v1`, `cors: true`, the environment header
`Content-Type: application/json`, and six routes:

| Route | Responses, in order | Rules |
|---|---|---|
| `GET users` | 200 with the file `users.json` and 300 ms of latency (the default); 200 with the file `inactive-users.json` | On the second: query `status` equals `inactive`. |
| `GET users/:id` | 200 with an inline template (the default); 404 | On the 404: params `id` regex `^0+$`. |
| `POST users` | 201 with an inline template; 403 (the default) | On the 201: header `X-Api-Key` equals `secret`, AND body `role` equals `admin`. |
| CRUD `orders` | The data bucket `orders`, `[{"id":1,"item":"book"},{"id":2,"item":"pen"}]` | None. |
| `GET exports/:id`, `SEQUENTIAL` | 200 with `{ "status": "running" }` (the default); 200 with `{ "status": "done" }` | None. |
| `POST password/reset` | 202 with `{ "message": "sent" }`; 429 with `Retry-After: 60` and `{ "error": "too many requests" }` (the default) | On the 202: `request_number` regex `^[12]$`. |

The two inline templates are:

```text
{ "id": "{{urlParam 'id'}}", "name": "{{faker 'person.fullName'}}", "lang": "{{queryParam 'lang' 'en'}}" }
{ "id": "{{faker 'string.uuid'}}", "name": "{{body 'name'}}" }
```

The steps below turn it into
[`defs/users-api.yaml`](examples/from-mockoon/defs/users-api.yaml), shown
whole [at the end](#the-result). They apply to any environment.

### List the routes Mockoon serves

- Mockoon tries routes in the order of the environment's `rootChildren`,
  with each folder's `children` in its place, depth first; the order of
  the `routes` array does not count. Folders change only the order,
  never a path
  ([folders](https://mockoon.com/docs/latest/api-endpoints/folders/)).
- A route switched off in the desktop app is still in the file, since
  Mockoon keeps those switches in the app's settings, and
  `--disable-routes` switches routes off for one CLI run. Leave such
  routes out. A file with an older `lastMigration` may still mark routes
  `"enabled": false`: the desktop app keeps them off, but Mockoon CLI 9.x
  drops the field and serves them, so leave them out only where they
  were meant to stay off.
- Check each route against
  [What smock does not do](#what-smock-does-not-do). Here every route has
  a counterpart, the CRUD route included
  ([below](#latency-cors-and-the-crud-route)).

### Declare the Mock

One environment becomes one Mock, best in a Definition file of its own:

```yaml
mocks:
  - name: users-api
    hosts: [localhost, users-api]
```

`hosts` lists the Hosts that clients send: `localhost` for a local run,
and `users-api` for clients that reach smock by that name, such as
through a Kubernetes Service. Hosts are compared without the port, so a
request for `users-api:3000` reaches this Mock too. As the only Mock,
`users-api` is also the Default Mock: a request for any other Host
reaches it as well, and its response carries
`Smock-Mock: users-api; via=default`.

Keep the Mock's `name` short and without spaces, such as `shop-api` for
an environment named `shop-api (provisional sample)`: the name is part
of Admin API paths, such as `/v1/mocks/shop-api/stubs`, and of the
`Smock-Mock` header, percent-encoded where it is not an HTTP token.

The environment's `port` and `hostname` have no place in the file. smock
listens on every IPv4 address (`0.0.0.0`), on the port that
`smock serve --port` gives, 8080 by default. Mockoon's `hostname` is the
address Mockoon listens on
([listening hostname](https://mockoon.com/docs/latest/server-configuration/listening-hostname/)),
and has no counterpart.

### Environments told apart by port

The example has one environment, so its file does not change here.
Mockoon serves each environment on a port of its own, and clients often
tell two environments apart only by port, such as `localhost:3000` and
`localhost:3001`. smock compares Hosts without the port, so there are two
ways to keep them apart:

- **One smock, with a Mock for each environment, told apart by Host.**
  Each Host belongs to one Mock, so only one of them can list
  `localhost`; the other needs a name of its own. With two Mocks, neither
  is the Default Mock unless one is marked `default: true`, and a request
  for a Host that no Mock lists, such as `127.0.0.1`, gets 404
  `no Mock for this Host`. So mark the Mock that lists `localhost`:

  ```yaml
  mocks:
    - name: shop-api
      hosts: [localhost, shop-api]
      default: true
    - name: auth-service
      hosts: [auth-service]
  ```

  Clients of `auth-service` must then send that Host: through DNS, a
  Kubernetes Service of that name, an `/etc/hosts` entry, or a `Host`
  header, as in `curl -H 'Host: auth-service' localhost:8080/auth/me`. A
  client of `auth-service` that still sends the Host `localhost`, such as
  one whose port 3001 was mapped to smock's, reaches `shop-api` without a
  sign. Its requests get `shop-api`'s answers, or a 404 whose
  `Smock-Near-Miss` names a `shop-api` Stub, and no `Smock-Mock` header,
  since `localhost` is `shop-api`'s own Host. In
  `GET /v1/journal/unmatched`
  ([Checking the migration](#checking-the-migration)), the entry's
  `host` and `mock` show the mix-up.
- **One smock for each environment.** Give each smock its own
  definitions directory with one Mock. Each Mock can then list
  `localhost`, and as the only Mock it is also the Default Mock of its
  smock, so clients keep their Host and their port. Each smock needs its
  own plain, TLS and Admin API ports; a second one on a port in use exits
  with `cannot listen` and `Address already in use`:

  ```sh
  export SMOCK_ADMIN_TOKEN=change-me
  smock serve --dir defs/shop-api --port 3000 --tls-port 3443 --admin-port 9090 &
  smock serve --dir defs/auth-service --port 3001 --tls-port 3444 --admin-port 9091 &
  ```

  In Docker, run one container for each, with `-p 3000:8080` and
  `-p 3001:8080`.

### One Stub per response

Mockoon serves the first response, in order, whose rules pass, and skips
responses without rules; when none passes, it serves the default
response, the one flagged as default or else the first
([multiple responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/),
[source](https://github.com/mockoon/mockoon/blob/fbeb141da66954019db89266c748aabc582d1897/packages/commons-server/src/libs/response-rules-interpreter.ts)).
So, for each route, in order:

1. Write a Stub for each response that has rules, in their order, with
   the route's method and path and the rules as conditions. Rules joined
   with AND go on one Stub; rules joined with OR, Mockoon's default, need
   one Stub each.
2. Write the default response last, with only the route's method and
   path as conditions. A default response with rules gets both: a Stub
   with its rules in its place in step 1, and this one.
3. Drop the other responses without rules: Mockoon never serves them.

The route's response mode changes this:

- `DISABLE_RULES`: only the default response, without its rules.
- `FALLBACK`: everything but the Stub of step 2. A request that passes no
  rule then goes on to the next route in Mockoon, and to the next Stubs
  in smock.
- `SEQUENTIAL`: a Stub for each response, in order and without its
  rules, each moving a Scenario on to the next
  ([Answers that change between requests](#answers-that-change-between-requests)).
- `RANDOM`: one Stub, with the route's method and path, that gives every
  response in `responses`, without their rules
  ([Random responses](#random-responses)).

In the example, `GET users` lists its default response first, but the
Stub of the response with a rule, `list-inactive-users`, comes before the
default's, `list-users`. In `POST users`, the response with two AND rules
becomes `create-user`, before the default `create-user-forbidden`.

Every Stub needs an `id`, unique in the whole definition set. A
response's `label` is a start, but a label may be empty, and labels such
as "Default" repeat from route to route, so build the ID from the route
too. A route's `documentation` becomes a YAML comment, and the `uuid`s
are dropped.

### Paths and request conditions

A route's path is the prefix and the endpoint, joined: `api/v1` and
`users` give `path: /api/v1/users`. An endpoint with parameters becomes a
pattern, in RE2 syntax, which must match the whole path
([pattern conditions](definition-files.md#pattern-conditions)):

| Mockoon endpoint | smock `path` |
|---|---|
| `users/:id` | `{ pattern: "/api/v1/users/[^/]+" }` |
| `users{/:id}`, or `users/:id?` in the older syntax | `{ pattern: "/api/v1/users(/[^/]+)?" }` |
| `files/*` | `{ pattern: "/api/v1/files/.+" }` |

A template reads a parameter by its position, not by its name:
`${path[n]}` is segment `n` of the path, counted from 0 after the leading
`/`, the prefix included. So `{{urlParam 'id'}}` becomes `${path[3]}` in
`/api/v1/users/42`. A wildcard's tail cannot be read as one value, only
segment by segment or as part of the whole `${path}`.

A `params` rule becomes part of the path pattern. The regex `^0+$` on
`id` gives the pattern `/api/v1/users/0+` of `get-user-missing`, which
comes before `get-user` just as the 404 response comes before the
default. A regex anchored at one end, or at neither, is widened with
`[^/]*`, which stays within the segment: `^DISC-` on `products/:sku`
gives `/api/v1/products/DISC-[^/]*`. Widened with `.*`, it would also
match `/api/v1/products/DISC-1/x`, a path that the route never takes.
The query rule of `GET users` becomes `query: { status: inactive }`, and
the two AND rules of `POST users` become `headers: { X-Api-Key: secret }`
and `body: { json: { role: admin } }` on one Stub.

Seven things need care when translating rules; [Rules](#rules) maps
every kind:

- **A Mockoon regex matches anywhere in the value; a smock pattern
  matches the whole value.** `^0+$` drops its anchors, and `admin`
  becomes `.*admin.*`, or `[^/]*admin[^/]*` in a path pattern. RE2 has no
  lookaround and no backreferences, and smock supports no `\p{…}`
  classes.
- **Mockoon's `equals` compares text; a `json` condition compares
  types.** The rule body `count` equals `1` holds for `{"count":1}` and
  for `{"count":"1"}`, but `{ json: { count: 1 } }` only for the first,
  so write values with the type that clients send. Where they send both,
  a pattern meets both, since it reads a number or a boolean by its text:
  `{ json: { count: { pattern: "1" } } }`. An array that contains the
  value also meets a Mockoon `equals` rule, while a `json` array needs
  every element, in order. For "contains", write `$includes`:
  `{ json: { tags: { $includes: b } } }` holds when an element of `tags`
  is `"b"`. It never holds for a value that is not an array, which the
  `equals` rule also meets, so where clients send `tags` as a single
  value too, add a Stub with `tags: b`.
- **Mockoon reads JSON and form bodies with the same rules; each smock
  body condition reads one format.** Mockoon parses a body by its
  Content-Type, and a rule's path reads whatever came out. In smock,
  `json` reads JSON, `form` reads `application/x-www-form-urlencoded`
  forms, and `xml` reads XML. So the rule body `role` equals `admin`
  becomes `body: { json: { role: admin } }` for clients that send JSON,
  and `body: { form: { role: admin } }` for clients that send forms; when
  clients send both, write a Stub for each. A form field's name is
  literal, as a query parameter's is: the rule `user.name`, which Mockoon
  reads from the field `user[name]`, becomes
  `form: { "user[name]": Alice }`. As in Mockoon, a body is read as a
  form only when its Content-Type says it is one, though smock compares
  the media type in any case, and Mockoon only in lower case. A multipart
  body can be matched only by a pattern on the whole body
  ([Behaviour that differs](#behaviour-that-differs)).
- **A regex on a field of a JSON body becomes a pattern in the field's
  place.** The rule body `email` regex `@example\.com$` becomes:

  ```yaml
  body: { json: { email: { pattern: '.*@example\.com' } } }
  ```

  A path such as `user.email`, or `$.user.email`, becomes nested keys,
  `{ user: { email: { pattern: … } } }`, and rules on several fields
  joined with AND go into one `json` condition. As in Mockoon, the
  pattern reads a string after its escapes are decoded, so it meets
  `"ann\u0040example.com"`, and it reads a number or a boolean by its
  text, so `123.*` meets `12345` and `1\.5` meets `1.50`. Three things
  still differ. Mockoon reads numbers as JavaScript does, which rounds
  `9007199254740993` to `9007199254740992` and reads `1e400` as
  `Infinity`; smock keeps every digit of an integer, and reads a number
  beyond a 64-bit float's range as written. Mockoon reads `null` as empty
  text and an object as `[object Object]`, and tests each element of an
  array; a smock pattern never meets `null`, an object or an array. A
  regex on the elements of an array becomes `$includes` with a pattern,
  `{ tags: { $includes: { pattern: "a.*" } } }`. An array index in the
  path, such as `items.0`, has no counterpart: a `json` array needs every
  element, and `$includes` finds an element wherever it sits.

  A body key named `pattern`, alone in its object and given a string,
  makes that object a pattern. For the rule body `filter.pattern` equals
  `a.b`, `{ filter: { pattern: a.b } }` is a pattern on `filter` itself,
  which never meets the object that clients send. Nest a pattern in it
  instead: `{ filter: { pattern: { pattern: 'a\.b' } } }`
  ([json conditions](definition-files.md#how-a-stub-matches-a-request)).
- **A rule on an XML body names an element by an XML path.** Mockoon
  turns an XML body into an object with xml-js, so its paths end in
  `_text` or name `_attributes`. An `xml` condition names elements and
  attributes by a path instead: `user.name._text` becomes `/user/name`,
  and `user._attributes.id` becomes `/user/@id`, as in
  `body: { xml: { /user/name: Alice, /user/@id: "7" } }`
  ([XML bodies](definition-files.md#xml-bodies)). The values differ in
  four ways. Mockoon keeps namespace prefixes, so a rule on
  `soap:Envelope.soap:Body.u:GetUser.u:id._text` fails when a client
  writes `S:Envelope`; smock ignores prefixes, and the path is
  `/Envelope/Body/GetUser/id`. Mockoon compares the text as written,
  without CDATA or the text of child elements, so `<name> Alice </name>`
  fails `Alice`; smock trims an element's text, and includes both. When
  an element repeats, Mockoon's path reaches an array and fails, unless
  an index such as `user.name.1._text` picks one; smock's path holds
  when any one of them meets the condition, and has no indexes. And
  Mockoon reads a body as XML only with the Content-Type
  `application/xml`, `text/xml` or `application/soap+xml`, while smock
  parses it whatever its Content-Type. Rules on `_declaration` have no
  counterpart.
- **A cookie rule becomes a `cookies` condition on the value as sent.**
  The rule cookie `session` equals `abc` becomes
  `cookies: { session: abc }`. Mockoon decodes the value and strips
  surrounding quotes, so its rule `abc` also meets `session="abc"`, and
  a rule `a b` meets `session=a%20b`. smock compares the value as the
  client sent it: write that form, such as `session: a%20b`, or a
  pattern that meets each form, such as `{ pattern: '"?abc"?' }`.
  Mockoon also trims spaces around `=` and reads only the first cookie
  of a name that repeats; smock does not trim there, and tests every
  cookie of the name. Both compare names case and all
  ([Cookies](definition-files.md#cookies)).
- **An inverted rule becomes `$not`.** `{ $not: … }` around the rule's
  value or pattern holds when the rule's condition does not, so, like
  the inverted rule, it holds when the name or key is absent. Take a
  route `GET accounts/:id` in another environment, `accounts-api`, also
  with the prefix `api/v1`. Its responses are a 401 with the inverted
  rule header `Authorization` regex `^Bearer\s+\S+`, a 404 for params
  `id` equals `0`, and the default 200. They become three Stubs, in the
  same order:

  ```yaml
  - id: account-unauthorized
    mock: accounts-api
    request:
      method: GET
      path: { pattern: "/api/v1/accounts/[^/]+" }
      headers: { Authorization: { $not: { pattern: 'Bearer\s+\S+.*' } } }
    response: { status: 401, json: { error: unauthorized } }

  - id: account-unknown
    mock: accounts-api
    request: { method: GET, path: /api/v1/accounts/0 }
    response: { status: 404, json: { error: unknown } }

  - id: account-found
    mock: accounts-api
    request: { method: GET, path: { pattern: "/api/v1/accounts/[^/]+" } }
    response: { status: 200, json: { id: 1 } }
  ```

  A request without `Authorization`, or with `Basic …`, gets the 401
  from both.

  Two kinds of inverted rule still need the route turned around. `$not`
  goes only where a value goes, so an inverted rule on the path, the
  method, `params` or the whole body as text has no place for it. And a
  body of the wrong format fails every condition on it, `$not` included:
  a body that is not JSON fails `json`, one whose Content-Type is not a
  form's fails `form`, and one that is not XML fails `xml`. Mockoon's
  inverted rule holds for such a body, so a `POST` without a body gets
  the inverted response from Mockoon, and the next Stub's from smock.
  Where clients send such bodies, turn the route around too.

  To turn a route around, give the rule's condition to the Stubs of the
  responses after the inverted one, since Mockoon reaches them only when
  that condition holds, and move them in front of the inverted response's
  Stub, which drops the condition and becomes the general Stub. Responses
  before it keep their place. For the inverted rule body `role` equals
  `admin` on a 403, followed by the default 200, the 200's Stub gets
  `body: { json: { role: admin } }` and goes first, and the 403's Stub
  follows it without a body condition.

### Bodies, headers and templates

- **Templates.** Mockoon renders every inline body, and every file of a
  text type, as a Handlebars template unless `disableTemplating` is set.
  smock renders a response only with `template: true`. A JSON body
  becomes `json`, where a string that is exactly one `${…}` keeps the
  value's type, or `body`, text sent as written. The template of
  `GET users/:id` becomes:

  ```yaml
  template: true
  json:
    id: ${path[3]}
    name: ${fake.name()}
    lang: ${query.lang ?? 'en'}
  ```

  [Template helpers](#template-helpers) maps the helpers. Mockoon's
  request helpers give an empty string for a value that the request
  lacks. In smock a missing value is an error, answered with 500 and
  `template failed`, unless `??` gives a fallback, as in
  `${body.name ?? ''}`. In templated content, a literal `${` is written
  `$${`.
- **Types.** Where the Handlebars template has no quotes around a value,
  as in `"id": {{urlParam 'id'}}`, Mockoon sends a number, `"id": 42`,
  while `id: ${path[3]}` gives the string `"42"`. Write
  `id: ${number(path[3])}` there. A number built from a helper and text,
  such as `{{faker 'number.int' min=5 max=60}}.99`, is computed with an
  arithmetic helper: `price: ${add(fake.int(5, 60), 0.99)}` gives a
  number such as `6.99`.
- **Structure.** `$if` and `$each` work only in `json`, and each gives one
  value. So an `{{#if}}` around several members becomes one `$if` for
  each member, with the condition repeated, and
  `{{#if (eq (queryParam 'currency') 'JPY')}}` becomes
  `$if: query.currency == 'JPY'`:

  ```yaml
  price:
    $if: query.currency == 'JPY'
    then: 1200
    else: 9.99
  currency:
    $if: query.currency == 'JPY'
    then: JPY
    else: EUR
  ```

  smock has no array literals, but `split` makes an array of strings
  from a literal text. So `{{#each (array 'SKU-1' 'SKU-2')}}` becomes
  `$each: "split('SKU-1,SKU-2', ',')"`, and an `{{add @index 1}}` in it
  becomes `${add(loop.index, 1)}`. An array of numbers or objects is
  written out, one element after the other. `{{setVar}}` has no
  counterpart: write its expression wherever `{{getVar}}` reads the
  variable.
- **Quoting.** In block style, as above, `${…}` needs no quotes. In a
  flow mapping, `{ id: ${path[3]} }` fails with
  `expected , or } in a flow mapping`; write `{ id: "${path[3]}" }`. A
  comma ends a value there too, so quote any value that has one, text or
  expression: `{ message: If it exists, we sent a mail. }` fails with
  `empty value: write null, or "" for an empty string`, and
  `{ message: "If it exists, we sent a mail." }` and
  `{ $each: "range(1, 3)", as: i, do: "${i}" }` work. Quote a header
  value that YAML would read as a number or a boolean, such as
  `Retry-After: "120"` and `Access-Control-Allow-Credentials: "true"`;
  unquoted, it fails with `must be a string or an array of strings`.
- **Headers.** Mockoon sends the environment's headers with every
  response, and a response's own headers replace those of the same name.
  `Set-Cookie` is the exception: Mockoon sends every value, the
  environment's first. smock has no environment headers: copy the ones
  that clients rely on into each Stub's `headers`, and, except
  Content-Type, into the Mock's `noMatch.headers` for the requests that
  no Stub matches ([Behaviour that differs](#behaviour-that-differs)).
  Here that is only `Content-Type: application/json`, which a `json` body
  gets by itself and the two body-file Stubs set. smock's YAML rejects
  anchors, aliases and merge keys (`anchors (&) are not supported`), so
  Stubs cannot share headers within a file; when many Stubs need the
  same headers, or the same delay, generate the file from a language that
  exports JSON
  ([another configuration language](definition-files.md#writing-definition-files-in-another-configuration-language)).
  Several `Set-Cookie` values become one name with an array of them, in
  the order Mockoon sends them:

  ```yaml
  headers:
    Set-Cookie:
      - session=abc; Path=/; HttpOnly
      - theme=dark; Path=/
  ```

  For any other key that a response lists more than once, Mockoon sends
  only the last value, so give the name that value as a string.
- **Empty bodies.** A new Mockoon response has the body `{}`. A Stub
  writes that as `json: {}`, since a Stub without a body sends an empty
  one.
- **Files.** A `FILE` body goes into `defs/files/`, and the Stub names it
  in `bodyFile`, relative to `files/`. Mockoon reads a relative
  `filePath` from the environment file's directory, so keep only the
  path below `defs/files/`: the example's `../defs/files/users.json`
  becomes `bodyFile: users.json`, and so would a `filePath` of
  `files/users.json`. Mockoon derives the Content-Type from the file's
  extension and smock does not, so set it. With Mockoon's default
  `sendFileAsBody: false`, Mockoon also sends
  `Content-Disposition: attachment` with the file's name: add that
  header if clients need it (the example's files have `sendFileAsBody`
  set to true). A body file is a template only with `template: true`,
  and must then be UTF-8. As in Mockoon, an untemplated body file answers
  Range requests
  ([file serving](https://mockoon.com/docs/latest/response-configuration/file-serving/)).
  smock serves a single byte range of a 200 to a GET, and a malformed
  `Range` gets the whole body with 200, where Mockoon answers 400
  ([Range requests](definition-files.md#range-requests);
  [Behaviour that differs](#behaviour-that-differs) has the other
  differences).
- **A templated file path and `fallbackTo404`.** A Stub names one fixed
  body file, and a missing body file makes the definition set invalid,
  which `smock check` reports. For a `filePath` such as
  `files/invoices/{{urlParam 'id'}}.pdf` on the route `invoices/:id/pdf`,
  write one Stub for each file that exists, with its exact path, then a
  Stub with the path pattern for the others. With `fallbackTo404`,
  Mockoon answers those with 404, the response's own headers and its
  inline body, and, with `sendFileAsBody: false`, a
  `Content-Disposition` with the requested name:

  ```yaml
  - id: invoice-a1
    mock: users-api
    request: { method: GET, path: /api/v1/invoices/A1/pdf }
    response:
      status: 200
      headers:
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="A1.pdf"
      bodyFile: invoices/A1.pdf

  - id: invoice-not-found
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/invoices/[^/]+/pdf" } }
    response:
      status: 404
      template: true
      headers:
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="${path[3]}.pdf"
      body: '{ "error": "invoice_not_found" }'
  ```

  Each new file then needs a Stub of its own.
- **Data buckets.** A `DATABUCKET` body becomes `json: "${data.NAME}"`,
  with `template: true`, which answers what the bucket holds for the
  request's Session ([Data buckets](#data-buckets)).

### Latency, CORS and the CRUD route

- **Latency.** Mockoon adds the environment's `latency` to each
  response's own. In smock, a delay is a Fault on the Stub, so
  `list-users` gets `fault: { delay: { fixed: 300 } }`. Mockoon's
  environment latency also delays the requests that no route answers;
  smock delays only the requests that a Stub with a delay matches.
  `--enable-random-latency`, which draws each latency from 0 to the
  value set, becomes `delay: { uniform: { min: 0, max: 300 } }`.
- **CORS.** With `cors: true`, Mockoon answers each `OPTIONS` request
  that no route takes with 200, an empty body and three
  `Access-Control-Allow-*` headers
  ([CORS](https://mockoon.com/docs/latest/server-configuration/cors/)),
  then adds the environment headers, which replace those of the same
  name. The Stub `preflight` does the same; it has the three defaults
  because this environment's only header is `Content-Type`, which an
  answer without a body does not need. When the environment headers
  hold CORS headers, start from the defaults and let the environment's
  CORS headers replace and extend them. With
  `Access-Control-Allow-Origin: http://localhost:5173` and
  `Access-Control-Allow-Credentials: true` among them, Mockoon's answer
  has those two and the default `Allow-Methods` and `Allow-Headers`.
  With the defaults alone, smock would send `*` and no
  `Allow-Credentials`, and a browser then refuses a request with
  credentials.

  `preflight` comes last, so that it is not named as the Near miss of
  requests that other Stubs nearly match: on a tie in failed conditions,
  the Near miss is the Stub tried first. Since it has only one condition,
  its method, it is still the Near miss of a request that fails two or
  more conditions of every other Stub, such as `HEAD /api/v1/status`,
  which gets `Smock-Near-Miss: preflight; failed=method`. The CRUD Stub
  `orders` fails only its path for a method that it serves, so
  `DELETE /api/v1/status` names `orders`. The CORS example in
  [docs/definition-files.md](definition-files.md#when-no-stub-matches)
  gives its preflight Stub a second condition,
  `headers: { Access-Control-Request-Method: { pattern: ".+" } }`, which
  every preflight meets. The 404 for that `HEAD` then names `list-users`,
  which fails its method and path, but an `OPTIONS` request without that
  header, which Mockoon answers, gets 404.

  Mockoon adds CORS headers to other responses, its 404 for a request
  that no route takes included, only when they are among the environment
  headers. In that case, copy them into the Stubs, into the CRUD Stub's
  `crud.headers` ([below](#latency-cors-and-the-crud-route)), and into
  the Mock's `noMatch.headers` for its no-match response
  ([Behaviour that differs](#behaviour-that-differs)).
- **The CRUD route.** The data bucket becomes a
  [Data bucket](definition-files.md#data-buckets) of the Mock, in the
  file's top-level `data`, and the CRUD route becomes a
  [CRUD Stub](definition-files.md#crud-stubs), in the route's place:

  ```yaml
  data:
    - mock: users-api
      name: orders
      key: id
      json: [{ id: 1, item: book }, { id: 2, item: pen }]

  stubs:
    # …
    - id: orders
      mock: users-api
      crud: { bucket: orders, path: /api/v1/orders }
  ```

  The bucket's content goes into `json`, or, for a large one, into a file
  in `defs/files/` that `jsonFile` names. `key` is the route's `crudKey`,
  written out when it is Mockoon's default, `id`. `crud.path` is the
  route's prefix and endpoint, joined, and `crud.bucket` names the bucket
  that the route's `databucketID` links. As the route does, the CRUD Stub
  lists and creates orders at `/api/v1/orders`, and reads, replaces,
  updates and deletes one at `/api/v1/orders/<id>`, with Mockoon's
  statuses, and with `X-Total-Count` and `X-Filtered-Count` on a list.
  Some answers differ in their details
  ([Behaviour that differs](#behaviour-that-differs)).

  Each Session reads and writes its own copy of the bucket, and requests
  without a Session share one ([Data buckets](#data-buckets)). So a test
  sees the orders it creates, and other tests do not:

  ```sh
  curl -H "baggage: smock-session=checkout-42" -d '{"item":"pencil"}' localhost:8080/api/v1/orders   # 201
  curl -H "baggage: smock-session=checkout-42" localhost:8080/api/v1/orders/3                       # 200
  curl localhost:8080/api/v1/orders/3                                                                # 404
  ```

  A Stub before the CRUD Stub takes over the requests it matches. So the
  route's other responses, which its rules pick in place of the CRUD
  operation, become ordinary Stubs before the CRUD Stub, and so does a
  route that Mockoon's docs place above the CRUD route to override one
  operation. `smock check` warns about such a Stub with a method and an
  exact path after the CRUD Stub, where it never answers
  ([Order and overrides](definition-files.md#order-and-overrides)).

  Mockoon adds the environment headers to the route's answers. When they
  hold CORS headers, give them to the CRUD Stub in `crud.headers`, which
  go on every answer, errors included. A browser reads `X-Total-Count`
  and `X-Filtered-Count` of a cross-origin answer only when
  `Access-Control-Expose-Headers` names them, which Mockoon does not
  send by itself:

  ```yaml
  - id: orders
    mock: users-api
    crud:
      bucket: orders
      path: /api/v1/orders
      headers:
        Access-Control-Allow-Origin: http://localhost:5173
        Access-Control-Allow-Credentials: "true"
        Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
  ```

  `preflight` stays: a CRUD Stub does not answer `OPTIONS`.

  A list reads smock's own parameters, not Mockoon's
  ([List queries](definition-files.md#list-queries)), so change the
  queries that clients send:

  | Mockoon | smock |
  |---|---|
  | `item_eq=book` | `item=book`, on a top-level member only. |
  | `sort=item`, `sort=item&order=asc` | `$sort=item` |
  | `sort=item&order=desc` | `$sort=-item` |
  | `page=3&limit=20` | `$offset=40&$limit=20`: `$offset` is `(page - 1) * limit`. |
  | `page=3` | `$offset=20&$limit=10`, with Mockoon's default `limit` of 10 written out. |
  | `limit=20` | `$limit=20` |
  | `search`, and the operators `_ne`, `_gt`, `_gte`, `_lt`, `_lte`, `_like`, `_start` and `_end` | No counterpart. |

  `GET /api/v1/orders?item_eq=book` thus becomes
  `GET /api/v1/orders?item=book`, which answers only the book, with
  `X-Total-Count: 2` and `X-Filtered-Count: 1`, as Mockoon does. A
  parameter that Mockoon does not read, such as jQuery's `_`, is ignored
  there, but filters in smock: no order has a member of that name, so the
  list is `[]`, with `X-Filtered-Count: 0`. A query that keeps Mockoon's
  parameters, such as `item_eq=book`, gets `[]` the same way. Where a
  client cannot change its query, an ordinary Stub before the CRUD Stub
  answers its lists ([List queries](definition-files.md#list-queries)
  shows one).

  Both counts keep Mockoon's meanings on every list: `X-Total-Count` is
  the number of items in the bucket, and `X-Filtered-Count` the number
  that pass the filters, before paging. json-server 0.17 gives
  `X-Total-Count` the second meaning, and sends it only with its paging
  parameters, so a client written for it reads the number that passes
  the filters there. Point such a client at `X-Filtered-Count`.

### Answers that change between requests

A `SEQUENTIAL` route serves its responses in turn, and from the first
again after the last; it ignores their rules and which one is the
default. A `request_number` rule tests the number of the route's
request, counted from 1. Both count every request that the route
answers, whatever the response, with one count for each route that all
clients share. The count starts over when Mockoon restarts, and on
`PURGE /mockoon-admin/state`
([multiple responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/),
[server state](https://mockoon.com/docs/latest/admin-api/server-state/)).

In smock, the Stubs of such a route share a
[Scenario](definition-files.md#scenarios). A Stub's `scenario` clause
names the Scenario, the state it `requires`, and the state it moves the
Scenario to (`moveTo`) when it answers. Every Scenario starts in the
state `Started`. Give each route a Scenario of its own, as Mockoon gives
each route its own count.

`GET exports/:id` is `SEQUENTIAL`. Each of its responses becomes a Stub
with the route's method and path, in order and without rules. The first
Stub requires `Started`, and each later one a state named after its
response. Each Stub moves the Scenario to the state of the next one, and
the last moves it back to `Started`, which closes the cycle:

```yaml
- id: get-export-running
  mock: users-api
  request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
  scenario: { name: export, requires: Started, moveTo: done }
  response: { status: 200, json: { status: running } }

- id: get-export-done
  mock: users-api
  request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
  scenario: { name: export, requires: done, moveTo: Started }
  response: { status: 200, json: { status: done } }
```

`GET /api/v1/exports/7` then answers `running`, `done`, `running`, and
so on. As in Mockoon, `GET /api/v1/exports/8` takes the next turn of the
same cycle. Without the `moveTo` of the last Stub, the Scenario stays at
`done`, which suits a client that polls until a job is done; Mockoon has
no such mode.

`POST password/reset` gives the first two requests 202 and every later
one 429. "The first N answers, then another" becomes a chain of states:
a Stub for each of the first N requests, each moving the Scenario on to a
state that counts it, then a Stub for the other answer, which requires
the last state and stays there:

```yaml
- id: reset-password-sent-1
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: Started, moveTo: sent once }
  response: { status: 202, json: { message: sent } }

- id: reset-password-sent-2
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: sent once, moveTo: sent twice }
  response: { status: 202, json: { message: sent } }

- id: reset-password-limited
  mock: users-api
  request: { method: POST, path: /api/v1/password/reset }
  scenario: { name: password-reset, requires: sent twice }
  response:
    status: 429
    headers: { Retry-After: "60" }
    json: { error: too many requests }
```

A state differs from Mockoon's count in three ways:

- **It is kept per Session and per replica.** Mockoon keeps one count
  for each route of the environment, and every client moves it. smock
  keeps a Scenario's state per
  [Session](../README.md#sessions-and-ephemeral-stubs), so concurrent
  tests each walk their own flow, and requests without a Session share
  a state of their own. Each replica keeps its own state, so tests that
  rely on Scenarios need one replica, or session affinity. Started side
  by side, the two answer these requests differently:

  ```sh
  curl localhost:8080/api/v1/exports/7                                      # running
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  curl localhost:8080/api/v1/exports/7                                      # done
  ```

  Mockoon, on port 3000, answers `running`, `done` and `running`: the
  second request takes the next turn of the one count. In smock, it
  starts the Session `test-a`'s own cycle, and the third request finds
  the cycle without a Session where the first left it.
- **Only a Stub with `moveTo` moves it.** Mockoon counts every request
  that the route answers. A Stub without a clause answers in every state
  and moves nothing. So when a route has a 400 for a malformed request
  as well, Mockoon counts the 400s towards `request_number`, and smock
  does not.
- **A reset starts it over.** `POST /v1/reset` with `{"scope":"session"}`
  clears the calling Session's Ephemeral Stubs, Journal entries,
  Scenario states, Variables and copies of Data buckets, which sends its
  Scenarios back to `Started`. `{"scope":"all"}` clears every Session's,
  as `PURGE /mockoon-admin/state` starts Mockoon's counts over, clears its
  global variables and resets its data buckets. A reset answers how many
  states, Variables and copies it cleared, in `removed.scenarioStates`,
  `removed.variables` and `removed.dataBuckets`.
  `PUT /v1/mocks/users-api/scenarios/export` with `{"state":"Started"}`
  starts one Scenario over, the calling Session's export cycle, and leaves
  its other Scenarios where they are. A test can also start over with a
  new Session, whose Scenarios are all in `Started`. Like Mockoon's
  counts, states are lost on restart.

  ```sh
  curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=test-a" \
    -d '{"scope":"session"}' localhost:9090/v1/reset
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  curl -X PUT -H "Authorization: Bearer change-me" -H "baggage: smock-session=test-a" \
    -d '{"state":"Started"}' localhost:9090/v1/mocks/users-api/scenarios/export
  curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/exports/7   # running
  ```

A state is a name that Stubs give, not data: it cannot keep a value from
a request, and templates cannot read it. Three other kinds of route
answer differently from one request to the next: a `RANDOM` route, a
route that reads a global variable, and a route that reads or writes a
data bucket. smock has `responses`, Variables and Data buckets for them.
The example environment has none of them but its CRUD route, so the
Stubs below are not in its file.

#### Random responses

A `RANDOM` route serves any of its responses, each as likely as the
others, and ignores their rules and which one is the default
([multiple responses](https://mockoon.com/docs/latest/route-responses/multiple-responses/)).
Its responses go into one Stub, as
[`responses`](definition-files.md#several-responses), without their
rules. Mockoon's `RANDOM` has no weights: Mockoon's
[issue 1016](https://github.com/mockoon/mockoon/issues/1016) asks for
them, and duplicated responses are the workaround there. smock takes
integer weights, so the copies of a response become one response whose
weight is their number. Say the example had a `RANDOM` route
`GET profile`, with a 200 and `{ "id": 7, "name": "Ann" }` three times
and a 503 with `Retry-After: 5` once. It becomes:

```yaml
- id: get-profile
  mock: users-api
  request: { method: GET, path: /api/v1/profile }
  responses:
    - { weight: 3, status: 200, json: { id: 7, name: Ann } }
    - { weight: 1, status: 503, headers: { Retry-After: "5" }, json: { error: unavailable } }
```

- As from Mockoon, about three requests in four get the 200, and the
  others the 503 and its `Retry-After`. Without copies, every response
  keeps the default weight of 1.
- Mockoon picks with JavaScript's `Math.random`, which `--faker-seed`
  does not seed, so no run can be repeated. smock picks from the
  request's one random draw, so
  [`fault.seed` and `--seed`](definition-files.md#seeds) replay the picks.
- Each response keeps its own status, headers, body and `template`. The
  conditions, the `fault` and the `scenario` clause stay one per Stub, so
  responses with latencies of their own share one delay.
- The [Journal](../README.md#the-journal) records which response each
  request got, as `responseIndex`, and `smock render` with `--response 1`
  renders the 503 ([Checking the migration](#checking-the-migration)).
  A test that needs the 503 on a given call, rather than by chance, adds
  an Ephemeral Stub that gives it for its Session
  ([Sessions and Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs)).

#### Global variables

A global variable keeps a value that one request sets for later ones
([global variables](https://mockoon.com/docs/latest/variables/global-variables/)).
Templates set it with `setGlobalVar` and read it with `getGlobalVar`. Say
the example had a route `POST login`, whose body template sets `user`,
and a route `GET me`, which reads it:

```text
{{setGlobalVar 'user' (body 'name')}}{ "message": "logged in" }
{ "name": "{{getGlobalVar 'user'}}" }
```

In smock, a Stub's `variables` write
[Variables](definition-files.md#variables) when the Stub matches, and
templates read them as `vars.NAME`. `?? ''` gives the empty text that
Mockoon gives for a value that is not there:

```yaml
- id: login
  mock: users-api
  request: { method: POST, path: /api/v1/login }
  variables:
    user: ${body.name ?? ''}
  response: { status: 200, json: { message: logged in } }

- id: get-me
  mock: users-api
  request: { method: GET, path: /api/v1/me }
  response:
    status: 200
    template: true
    json: { name: "${vars.user ?? ''}" }
```

```sh
curl -H "baggage: smock-session=test-a" -d '{"name":"Ann"}' localhost:8080/api/v1/login
curl -H "baggage: smock-session=test-a" localhost:8080/api/v1/me   # {"name":"Ann"}
curl localhost:8080/api/v1/me                                      # {"name":""}
```

A Variable differs from a global variable in five ways:

- **It is kept per Mock and Session.** Mockoon keeps one set of global
  variables for each environment, and every client reads and writes it.
  smock keeps Variables per Mock and per Session, as it keeps Scenario
  states, so the last request above, which names no Session, does not
  see `Ann`. Each replica keeps its own.
- **A Stub field sets it, when the Stub matches.** Mockoon sets a global
  variable while a template renders. smock writes a Stub's `variables` at
  the match decision, before the delay and before the response is
  built, and the response sees the new values. No template sets a
  Variable, and no condition reads one, as the `global_var` rule target
  does in Mockoon.
- **It holds any JSON value, written as a template.** Each value of
  `variables` is a template, rendered against the Variables as they were
  before the request, so `count: ${add(vars.count ?? 0, 1)}` counts
  requests. A path that `getGlobalVar` takes becomes steps:
  `{{getGlobalVar 'user' 'address.city'}}` becomes
  `${vars.user.address.city ?? ''}`. One byte bound holds every Variable,
  and a request whose writes would pass it gets 507
  ([The state bound](definition-files.md#the-state-bound)).
- **Resets clear it.** `POST /v1/reset` clears the Variables in its
  scope, as `PURGE /mockoon-admin/state` and
  `PURGE /mockoon-admin/global-vars` clear Mockoon's
  ([Resets and reloads](definition-files.md#resets-and-reloads)). A
  reload of the files keeps them, except those of a Mock that the files
  no longer declare, and both tools lose them on restart.
- **The Admin API lists and sets it.** `GET /v1/mocks/users-api/variables`
  lists the calling Session's Variables, which Mockoon's Admin API
  cannot do for global variables, and `PUT` and `DELETE` on
  `/v1/mocks/users-api/variables/user` set and delete one
  ([Through the Admin API](definition-files.md#through-the-admin-api)).

#### Data buckets

Beyond CRUD routes, Mockoon's templates read data buckets with the
`data` and `dataRaw` helpers and write them with `setData`, and a
response with `bodyType: DATABUCKET` serves a bucket whole
([using data buckets](https://mockoon.com/docs/latest/data-buckets/using-data-buckets/)).
In smock, templates read a bucket as `data.NAME`, and a Stub's
[`dataWrites`](definition-files.md#writing-buckets-datawrites) write it
when the Stub matches. Say the example had a bucket `visits` holding `0`,
and a route `POST visit` whose body template counts the calls:

```text
{{setData 'inc' 'visits'}}{ "visits": {{data 'visits'}} }
```

It becomes a bucket and a Stub:

```yaml
data:
  - { mock: users-api, name: visits, json: 0 }

stubs:
  - id: visit
    mock: users-api
    request: { method: POST, path: /api/v1/visit }
    dataWrites:
      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
```

```sh
curl -X POST -H "baggage: smock-session=test-a" localhost:8080/api/v1/visit   # {"visits":1}
curl -X POST -H "baggage: smock-session=test-a" localhost:8080/api/v1/visit   # {"visits":2}
curl -X POST localhost:8080/api/v1/visit                                       # {"visits":1}
```

The value of a write is rendered against the data from before the
request, and the response reads the data after it, so the Stub counts as
the route does. Each `setData` operation becomes a write:

| Mockoon | smock |
|---|---|
| `{{setData 'set' 'cart' '' (bodyRaw)}}` | `{ op: set, bucket: cart, value: "${body}" }` |
| `{{setData 'merge' 'profile' '' (bodyRaw)}}` | `{ op: merge, bucket: profile, value: "${body}" }`, a shallow merge into the object that the bucket holds. |
| `{{setData 'push' 'cart' '' (bodyRaw)}}` | `{ op: append, bucket: cart, value: "${body}" }`, onto the array that the bucket holds. |
| `{{setData 'del' 'cart'}}` | `{ op: set, bucket: cart, value: null }`, or `[]` for a bucket with `key`, which holds an array. |
| `{{setData 'inc' 'visits' '' 2}}`, `{{setData 'dec' 'visits'}}` | `{ op: set, bucket: visits, value: "${add(data.visits, 2)}" }`, `{ op: set, bucket: visits, value: "${subtract(data.visits, 1)}" }` |
| `{{setData 'invert' 'enabled'}}` | `{ op: set, bucket: enabled, value: { $if: data.enabled, then: false, else: true } }` |
| A path into the value, such as `{{setData 'set' 'profile' 'address.city' 'Kyoto'}}` | No counterpart, except one item of a bucket with `key`: `set`, `merge` and `remove` take the item's `key`, where Mockoon takes its index, so `{{setData 'del' 'orders' '0'}}` becomes `{ op: remove, bucket: orders, key: "1" }` for the first order, whose `id` is 1. |

A Data bucket differs from a data bucket of Mockoon in five ways:

- **It is kept per Mock and Session.** Mockoon keeps one value for each
  bucket, which every client reads and writes. A smock Session reads the
  initial value until it first writes to the bucket, which gives it a
  copy of its own. Requests without a Session share one copy, and each
  replica keeps its own copies. So the last request above, which names no
  Session, counts from the start.
- **A Stub field writes it, when the Stub matches.** Mockoon writes while
  a template renders, and a CRUD route writes after the response's
  latency. smock writes at the match decision, before the delay and
  before the response is built, all of a Stub's writes and Variables or
  none of them. A write that cannot be applied, such as an `append` to a
  bucket that holds no array, answers 500 `data write failed`, where
  `setData` does nothing ([When a write fails](definition-files.md#when-a-write-fails)).
  No condition reads a bucket, as the `data_bucket` rule target does in
  Mockoon.
- **It is named exactly.** Mockoon's helpers find a bucket by its `id`,
  or by any part of its name, in any case, so `{{data 'ord'}}` reads the
  bucket `orders`. `data.orders` names it in full, and a name that the
  Mock does not declare is an error when the files load.
- **Its initial value is static JSON.** Mockoon renders a bucket's
  content as a template
  ([Behaviour that differs](#behaviour-that-differs)).
- **Resets drop it, and the Admin API sets it.** `POST /v1/reset` drops
  the copies in its scope, as `PURGE /mockoon-admin/data-buckets` resets
  Mockoon's buckets. A reload keeps a copy unless its bucket's initial
  value or `key` changed
  ([Copies in resets and reloads](definition-files.md#copies-in-resets-and-reloads)),
  and both tools lose them on restart. `GET /v1/mocks/users-api/data`
  lists the Mock's buckets, and `GET`, `PUT` and `DELETE` on
  `/v1/mocks/users-api/data/visits` read, set and drop the calling
  Session's copy
  ([Data buckets through the Admin API](definition-files.md#data-buckets-through-the-admin-api)).
  Mockoon's Admin API reads buckets, but cannot set one.

A CRUD Stub serves only a bucket with `key`, at its list path and its
item paths. Two kinds of CRUD route need ordinary Stubs instead:

- **`PUT`, `PATCH` and `DELETE` on the whole list.** A CRUD Stub does not
  match them, so they reach later Stubs. A `PUT` replaces the list with
  `set`, and a `DELETE` empties it with `set` to `[]`, where Mockoon
  leaves the bucket with no value:

  ```yaml
  - id: replace-orders
    mock: users-api
    request: { method: PUT, path: /api/v1/orders }
    dataWrites:
      - { op: set, bucket: orders, value: "${body}" }
    response: { status: 200, template: true, json: "${data.orders}" }

  - id: delete-orders
    mock: users-api
    request: { method: DELETE, path: /api/v1/orders }
    dataWrites:
      - { op: set, bucket: orders, value: [] }
    response: { status: 200, json: {} }
  ```

  A `PATCH` on the list becomes an `append` of `${body}` when clients
  send one item. Mockoon adds each item of an array body, which a write
  cannot do.
- **A bucket that is not an array of objects with keys.** Mockoon serves
  an object, a number or a text whole, at the route's path and at any item
  path, and the elements of an array of other values by index. Stubs
  that read `data.NAME` and write with `set` and `merge` serve such a
  bucket at its path:

  ```yaml
  data:
    - { mock: users-api, name: settings, json: { theme: light, lang: en } }

  stubs:
    - id: get-settings
      mock: users-api
      request: { method: GET, path: /api/v1/settings }
      response: { status: 200, template: true, json: "${data.settings}" }

    - id: replace-settings
      mock: users-api
      request: { method: PUT, path: /api/v1/settings }
      dataWrites:
        - { op: set, bucket: settings, value: "${body}" }
      response: { status: 200, template: true, json: "${data.settings}" }

    - id: update-settings
      mock: users-api
      request: { method: PATCH, path: /api/v1/settings }
      dataWrites:
        - { op: merge, bucket: settings, value: "${body}" }
      response: { status: 200, template: true, json: "${data.settings}" }
  ```

  Elements read by index have no counterpart, since a template's index
  is a number written in it.

### The result

The whole Definition file:

```yaml
# The Mockoon environment ../mockoon/users-api.json as a Definition file.
# Each group of Stubs is one Mockoon route, in the environment's order.
mocks:
  - name: users-api
    hosts: [localhost, users-api]

# The data bucket "orders", with its initial value. Its key is the CRUD
# route's crudKey.
data:
  - mock: users-api
    name: orders
    key: id
    json: [{ id: 1, item: book }, { id: 2, item: pen }]

stubs:
  # GET users: lists the users; ?status=inactive lists the inactive ones.
  # The response with a rule comes first, the default response last.
  - id: list-inactive-users
    mock: users-api
    request: { method: GET, path: /api/v1/users, query: { status: inactive } }
    response:
      status: 200
      headers: { Content-Type: application/json }
      bodyFile: inactive-users.json

  - id: list-users
    mock: users-api
    request: { method: GET, path: /api/v1/users }
    response:
      status: 200
      headers: { Content-Type: application/json }
      bodyFile: users.json
    fault:
      delay: { fixed: 300 }

  # GET users/:id: the 404 for IDs made of zeros, then the default response.
  - id: get-user-missing
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/users/0+" } }
    response: { status: 404, json: { error: not found } }

  - id: get-user
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/users/[^/]+" } }
    response:
      status: 200
      template: true
      json:
        id: ${path[3]}
        name: ${fake.name()}
        lang: ${query.lang ?? 'en'}

  # POST users: both rules (AND) on one Stub, the default response last.
  - id: create-user
    mock: users-api
    request:
      method: POST
      path: /api/v1/users
      headers: { X-Api-Key: secret }
      body: { json: { role: admin } }
    response:
      status: 201
      template: true
      json:
        id: ${fake.uuid()}
        name: ${body.name ?? ''}

  - id: create-user-forbidden
    mock: users-api
    request: { method: POST, path: /api/v1/users }
    response: { status: 403, json: { error: forbidden } }

  # orders: a CRUD route on the data bucket "orders". It lists, creates,
  # reads, replaces, updates and deletes orders.
  - id: orders
    mock: users-api
    crud: { bucket: orders, path: /api/v1/orders }

  # GET exports/:id: SEQUENTIAL, so its responses take turns. Each answer
  # moves the Scenario "export" to the next one, and the last back to
  # Started.
  - id: get-export-running
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
    scenario: { name: export, requires: Started, moveTo: done }
    response: { status: 200, json: { status: running } }

  - id: get-export-done
    mock: users-api
    request: { method: GET, path: { pattern: "/api/v1/exports/[^/]+" } }
    scenario: { name: export, requires: done, moveTo: Started }
    response: { status: 200, json: { status: done } }

  # POST password/reset: a request_number rule gives the first two requests
  # 202 and every later one 429. The Scenario "password-reset" counts them.
  - id: reset-password-sent-1
    mock: users-api
    request: { method: POST, path: /api/v1/password/reset }
    scenario: { name: password-reset, requires: Started, moveTo: sent once }
    response: { status: 202, json: { message: sent } }

  - id: reset-password-sent-2
    mock: users-api
    request: { method: POST, path: /api/v1/password/reset }
    scenario: { name: password-reset, requires: sent once, moveTo: sent twice }
    response: { status: 202, json: { message: sent } }

  - id: reset-password-limited
    mock: users-api
    request: { method: POST, path: /api/v1/password/reset }
    scenario: { name: password-reset, requires: sent twice }
    response:
      status: 429
      headers: { Retry-After: "60" }
      json: { error: too many requests }

  # cors: true answers every OPTIONS request. Last, so that it is not
  # named as the Near miss of requests that other Stubs nearly match.
  - id: preflight
    mock: users-api
    request: { method: OPTIONS }
    response:
      status: 200
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS
        Access-Control-Allow-Headers: Content-Type, Origin, Accept, Authorization, Content-Length, X-Requested-With
```

Started side by side, with
`mockoon-cli start --data mockoon/users-api.json --port 3000` and
`SMOCK_ADMIN_TOKEN=change-me smock serve --dir defs`, the two answer:

| Request | Mockoon | smock |
|---|---|---|
| `GET /api/v1/users` | 200 after about 0.3 s, the bytes of `users.json` | The same. |
| `GET /api/v1/users?status=inactive` | 200, the bytes of `inactive-users.json` | The same. |
| `GET /api/v1/users/42?lang=ja` | 200, `{ "id": "42", "name": "<fake name>", "lang": "ja" }` | 200, `{"id":"42","name":"<fake name>","lang":"ja"}` |
| `GET /api/v1/users/000` | 404, `{ "error": "not found" }` | 404, `{"error":"not found"}` |
| `POST /api/v1/users` with `X-Api-Key: secret` and the JSON `{"name":"Alice","role":"admin"}` | 201, `{ "id": "<UUID>", "name": "Alice" }` | 201, `{"id":"<UUID>","name":"Alice"}` |
| The same with `"role":"viewer"` | 403, `{ "error": "forbidden" }` | 403, `{"error":"forbidden"}` |
| `OPTIONS /api/v1/users` | 200, the three CORS headers, no body | 200, the three CORS headers, no body and no Content-Type |
| `GET /api/v1/orders` | 200, the two orders, `X-Total-Count: 2`, `X-Filtered-Count: 2` | The same. |
| `GET /api/v1/orders/1` | 200, `{"id":1,"item":"book"}` | The same. |
| `POST /api/v1/orders` with the JSON `{"item":"pencil"}`, then `GET /api/v1/orders/3` | 201, `{"item":"pencil","id":3}`, then 200 with the new order | The same, and the 201 carries `Location: /api/v1/orders/3`. |
| `GET /api/v1/exports/7`, three times | 200, `{ "status": "running" }`, then `done`, then `running` again | 200, `{"status":"running"}`, then `done`, then `running` again |
| `POST /api/v1/password/reset`, three times | 202, `{ "message": "sent" }`, twice, then 429, `Retry-After: 60` and `{ "error": "too many requests" }` | 202, `{"message":"sent"}`, twice, then 429, `Retry-After: 60` and `{"error":"too many requests"}` |

Mockoon's JSON responses, and its `OPTIONS` answer, carry
`Content-Type: application/json; charset=utf-8`; smock's JSON responses
carry `application/json`, and its `OPTIONS` answer none.

## Behaviour that differs

Even a faithful translation answers some requests differently. These
differences were checked against Mockoon CLI 9.9.0 from 2026-10-17 to
2026-10-22, most of them by sending the same requests to both servers,
with the example or with small environments made to test them:

- **Paths.** Mockoon matches paths case-insensitively, accepts a trailing
  slash and merges repeated slashes. smock compares the decoded path
  exactly, so `GET /API/V1/USERS` and `GET /api/v1/users/` reach
  `list-users` in Mockoon and get 404 from smock. Where clients rely on
  that, use a pattern such as `(?i)/api/v1/users/?`.
- **Request bodies.** Mockoon parses JSON, form, multipart and XML bodies
  by their Content-Type before its rules read them
  ([supported body formats](https://mockoon.com/docs/latest/requests/supported-body-formats/)),
  and a rule with a path reads whichever it got. Each smock body
  condition reads one format: `json` and `xml` parse the body whatever
  its Content-Type, and `form` reads it only with the form Content-Type.
  So the form `name=Alice&role=admin`, sent with the key to
  `POST /api/v1/users`, gets 201 from Mockoon and 403 from smock, whose
  `create-user` has only a `json` condition, and the same JSON without a
  Content-Type gets 403 from Mockoon and 201 from smock. A second Stub
  with `body: { form: { role: admin } }` would take the form, but its
  answer could not repeat the name: in a template, `${body.x}` reads
  JSON bodies only.
- **Content-Type.** Mockoon adds `; charset=utf-8` to the Content-Type of
  a body it sends as text: an inline body, whatever its type, so
  `application/json; charset=utf-8` and `text/plain; charset=utf-8`, and
  even `application/pdf; charset=utf-8` for a `fallbackTo404` body; and a
  file of a type that it renders as a template, such as JSON. It sends
  other files, such as a PDF, with the type alone, and an inline body
  with no Content-Type configured as `text/html; charset=utf-8`. smock
  sends the Content-Type exactly as the Stub gives it; without one, a
  `json` body gets `application/json`, and other bodies get none. Where
  clients compare the whole value, give it with the charset, as in
  `Content-Type: application/json; charset=utf-8`.
- **Body bytes.** Mockoon sends an inline body with the spacing it was
  written with. smock writes `json` compactly, numbers in their shortest
  form (`9.90` as `9.9`), except the output of `fake.decimal`, which
  keeps its places (`25.00`). Compare bodies after `jq -S`, or write the
  body as `body` text where the exact bytes matter.
- **Escaping.** Mockoon's `body` and `queryParam` helpers insert values
  as they are, so `GET /api/v1/users/7?lang=a%22b` makes the example's
  body invalid JSON in Mockoon. Its other values, `urlParam` and
  `header` among them, are escaped for HTML: `GET /api/v1/users/a%22b`
  answers `"id": "a&quot;b"`. smock escapes every inserted value for the
  response's Content-Type, and in `json` always as JSON, so it answers
  `"lang":"a\"b"` and `"id":"a\"b"`; it escapes for HTML only in HTML
  and XML responses.
- **Unmatched requests.** Mockoon answers a request that no route takes
  with 404, the `text/html` page "Cannot GET /path", and the environment
  headers, CORS headers among them, except a few that it replaces or
  drops for that page, such as Content-Type and Content-Language. smock
  answers with the Mock's `noMatch.status`, 404 by default, the body
  `{"error":"no Stub matched"}`, a header such as
  `Smock-Near-Miss: list-users; failed=path`, and the Mock's
  `noMatch.headers`. Copy there the environment headers that clients rely
  on, except Content-Type, which smock sets to `application/json`.
  Without the CORS headers, a page on another origin that reads a 404
  from Mockoon gets a CORS error from smock. For the environment headers
  `Access-Control-Allow-Origin: http://localhost:5173` and
  `Access-Control-Allow-Credentials: true`, the Mock becomes:

  ```yaml
  mocks:
    - name: users-api
      hosts: [localhost, users-api]
      noMatch:
        headers:
          Access-Control-Allow-Origin: http://localhost:5173
          Access-Control-Allow-Credentials: "true"
          Access-Control-Expose-Headers: Smock-Near-Miss
  ```

  The last header, which Mockoon does not send, lets that page read the
  Near miss too.
- **Sequences and request numbers.** Mockoon keeps one count for each
  route, which every client moves. smock keeps a Scenario's state for
  each Session, in each replica, and moves it only when a Stub with
  `moveTo` answers
  ([Answers that change between requests](#answers-that-change-between-requests)).
- **Random responses.** No run of a Mockoon `RANDOM` route can be
  repeated. smock's pick follows `fault.seed` and `--seed`, and its
  weights stand for copies of a response
  ([Random responses](#random-responses)).
- **Global variables.** Mockoon keeps one set for each environment, which
  every client reads and writes, and its templates set them. smock keeps
  Variables for each Mock and Session, in each replica, and writes them
  when a Stub matches ([Global variables](#global-variables)).
- **Data buckets.** Mockoon keeps one value for each bucket, which every
  client reads and writes, and writes it while a template renders, or
  after the latency of a CRUD route's response. smock keeps a copy for
  each Mock and Session, in each replica, and writes it when a Stub
  matches, before any delay ([Data buckets](#data-buckets)).
- **Bucket content.** Mockoon renders a bucket's content as a Handlebars
  template when it starts, and again on a purge, so `{{faker …}}` in it
  gives new data each time. smock never templates a bucket: every Session
  starts from the same JSON. To keep the data that Mockoon generated,
  start it with `--admin-api-token change-me`, read the bucket by its
  `id`, and save its value as the bucket's `jsonFile`:

  ```sh
  curl -s -H "Authorization: Bearer change-me" localhost:3000/mockoon-admin/data-buckets/ordr |
    jq .value >defs/files/orders.json
  ```

  A bucket whose content reads the request, such as with `body` or
  `urlParam`, is generated when a route first uses it, so send that
  request first. A key written as a template also makes the keys of
  Mockoon's creates: a key such as `"id": "{{faker 'string.uuid'}}"`
  becomes `newKey: uuid`, and other key templates have no counterpart.
- **CRUD routes.** A CRUD Stub answers some requests differently from a
  CRUD route:
  - A CRUD Stub compares its paths exactly, as other Stubs do, and takes
    no pattern: `GET /API/V1/ORDERS` and `GET /api/v1/orders/` reach the
    CRUD route, and get 404 from smock.
  - A missing item gets 404 with `{}` from Mockoon, and with
    `{"error":"no item with this key","stub":"orders","key":"9"}` from
    smock.
  - A delete answers `{}` in Mockoon, and the removed item in smock.
  - A create answers with `Location`, such as `/api/v1/orders/3`, in
    smock only.
  - A `PUT` or `PATCH` whose body holds another key changes the item's key
    in Mockoon. smock keeps the key, and answers 400
    `key does not match the path`.
  - A body that is not a JSON object is stored by Mockoon: a JSON text,
    such as `"pen"`, is added as it is, and a create without a body adds
    an item that holds only a new key. smock answers 400
    `body is not a JSON object`, and stores nothing. A create whose key
    an item has adds a second item with that key in Mockoon, and gets 409
    `key already exists` from smock.
  - smock reads the body as JSON whatever its Content-Type. Mockoon reads
    JSON only with a JSON Content-Type, so `curl -d '{"item":"pencil"}'`,
    which sends a form's, stores an item with one form field, named
    `{"item":"pencil"}`.
  - Mockoon sorts texts in lower case, so `apple` comes before `Book`.
    smock sorts them by code point, case-sensitively, so `Book` comes
    before `apple`.
  - A list parameter that Mockoon does not read is ignored there, and is
    a filter in smock, which no item meets
    ([The CRUD route](#latency-cors-and-the-crud-route)).
  - A create without a key gets one more than the highest numeric key in
    both. With no numeric key, an empty bucket included, Mockoon gives a
    UUID, and smock gives 1, or the next integer that no key has, unless
    the bucket takes `newKey: uuid`. Give that to a bucket whose keys are
    UUIDs.
- **Range requests.** Both serve byte ranges only from a body file that
  is not a template, but they differ in what they serve:
  - Mockoon serves a range to any method, such as `POST`, and in place
    of any status, a 404 included. smock serves one only to a `GET` of a
    200.
  - For a malformed `Range`, such as `bytes=abc`, Mockoon answers 400.
    For a range whose last position is below its first, such as
    `bytes=5-2`, it answers 416. For several ranges it sends the first,
    and it takes another unit, such as `items=0-5`, as bytes. It ignores
    `If-Range`. smock sends the whole body with 200 in each of these
    cases.
  - Mockoon's 416 carries no `Content-Range`, and its body is the text
    `Requested range not satisfiable`. smock's carries
    `Content-Range: bytes */<length>` and no body, along with the Stub's
    headers.
  - Mockoon sends `Accept-Ranges: bytes` only with a 206. smock also
    sends it with the 200 of a body file that serves ranges.

  [Range requests](definition-files.md#range-requests) has smock's
  rules.
- **Latency of unmatched requests.** Mockoon's environment latency delays
  its 404s too. A smock delay applies only to the requests its Stub
  matches.
- **HEAD.** Neither answers `HEAD /api/v1/users` from its `GET` route or
  Stub: both send 404.
- **Hosts.** Mockoon does not look at the Host. With several Mocks, smock
  sends a request for a Host that no Mock lists to the Default Mock,
  marked `via=default`, or answers 404 `no Mock for this Host` when
  there is no Default Mock
  ([Hosts and the Default Mock](definition-files.md#hosts-and-the-default-mock)).
- **Template errors.** Mockoon answers a template that fails with the
  response's own status and a `text/plain` message. smock finds most
  template errors when it loads the files, and answers one that fails
  for a request with 500 and `{"error":"template failed",…}`. Most
  Mockoon helpers never fail: an unknown helper gives an empty text, and
  a value of the wrong kind gives an empty text, `NaN`, or is skipped, so
  `{{add '1' '2' 'dolphins' '3'}}` gives `6`. smock reports an unknown
  helper, and a literal of the wrong kind, when it loads the files, and a
  value of the wrong kind from the request fails the template, so
  `${add(query.n, 1)}` with `?n=dolphins` gets the 500. A few Mockoon
  helpers fail where smock's do not: `{{uppercase 5}}` fails, and
  `${uppercase(5)}` gives `5`.
- **Text.** Mockoon counts the length of a text and the positions in it
  in UTF-16 units, as JavaScript does, so `{{len '😀'}}` gives `2`, and
  `substr` can cut an emoji in two. smock counts code points, so
  `len('😀')` gives `1`.
- **Request size.** Mockoon accepts request bodies up to 100 MB by
  default; smock accepts up to 10 MiB (`--body-limit`), and answers
  longer ones with 413.
- **Fake data.** smock draws names and words from built-in lists of ASCII
  names and English words, with no locale. `fault.seed` on a Stub
  repeats them from run to run, and so does `--seed` for the same
  requests in the same order, as `--faker-seed` does in Mockoon.
- **Dates.** Both write dates with date-fns format tokens, so
  `{{now 'yyyy-MM-dd'}}` becomes `${now('yyyy-MM-dd')}`, but six things
  differ:
  - Mockoon writes local time, in its process's time zone, with an
    offset: `{{now}}` gives `2026-10-17T14:01:59.615+00:00` in UTC, and
    `2026-10-17T23:01:59.615+09:00` under `TZ=Asia/Tokyo`. smock writes
    UTC with `Z`: `now()` gives `2026-10-17T14:01:59.615Z`. Where clients
    compare the text, write
    `${now("yyyy-MM-dd'T'HH:mm:ss.SSSxxx")}`, which gives `+00:00`, or
    `dateFormat` with a fixed offset, such as
    `${dateFormat(now(), "yyyy-MM-dd'T'HH:mm:ss.SSSxxx", '+09:00')}`.
  - Mockoon takes the week-numbering year (`YYYY`, `YY`) and the day of
    the year (`DD`, `D`) where it finds them, so a format of
    `yyyy-MM-DD`, which Mockoon's own documentation shows, writes
    `2026-02-36` on February 5. smock refuses those tokens when it loads
    the files: write `yyyy` and `dd`.
  - Mockoon reads a date with JavaScript's `new Date(…)`, which takes a
    date-time without an offset as local time, and other texts by rules
    of its own. smock takes an RFC 3339 date-time with an offset, a date
    `YYYY-MM-DD` or epoch milliseconds, and nothing else: any other value
    is missing, so `??` gives a fallback.
  - Mockoon's `dateTimeShift` rolls a day past the end of the month over
    into the next one, so January 31, 2026 plus one month is March 3.
    smock stops at the last day of the month, February 28.
  - Mockoon shifts days first, then months and years; smock shifts years
    and months first, then days.
  - Mockoon writes the year 0, 1 BC, under `yyyy` and `yy` as date-fns's
    year of the era, `0001` and `01`, so
    `{{dateFormat '0000-06-01' 'yyyy-MM-dd'}}` gives `0001-06-01`. smock
    writes the calendar year, `0000` and `00`, as its RFC 3339 times do,
    so `${dateFormat('0000-06-01', 'yyyy-MM-dd')}` gives `0000-06-01`.
- **Logs.** The Mockoon CLI logs every request. smock logs none, and
  records them in the Journal instead.

## Checking the migration

`smock check` reads a definitions directory as `smock serve` would, and
prints every problem with its file and a JSON Pointer. It also warns
about two things that often show a slip in the translation
([warnings](definition-files.md#warnings)): a Stub that can never match
because an earlier one always matches first, which often means that
responses were written in the wrong order, and a state that a Stub
requires but no Stub moves to, which often means a typo in a state name:

```sh
smock check defs   # prints nothing and exits with 0 for the example
```

In CI, run it as a step that fails the build: `- run: smock check defs`.

The first warning compares a pattern only with an exact path, never with
another pattern ([warnings](definition-files.md#warnings)), so it misses
two Stubs in the wrong order whose paths are both patterns: with
`get-user` declared before `get-user-missing`, `smock check` prints
nothing, and `GET /api/v1/users/000` gets 200. Those are the Stubs of
routes with parameters, so check them with `smock render` or with
requests, as below.

`smock render` shows, without a server, what one Stub answers to a
sample request, and which of the Stub's conditions the sample fails. The
sample is JSON,
`{method, path, query, headers, body, session, vars, data}`, every
member optional, with the path and the query values decoded and the
cookies in `headers.Cookie`, and `--seed` makes the fake data
repeatable:

```sh
echo '{"method":"GET","path":"/api/v1/users/42","query":{"lang":"ja"}}' >sample.json
smock render --dir defs --request sample.json --seed 7 get-user |
  jq -c '[.response.status, .response.body.data, .failed]'
# [200,"{\"id\":\"42\",\"name\":\"Sebastian Garcia\",\"lang\":\"ja\"}",[]]
```

It renders the CRUD Stub too, with the answer its operation would give
from the bucket's initial value, or from the sample's `data`, and writes
nothing. So a list query can be checked before clients send it:

```sh
echo '{"method":"GET","path":"/api/v1/orders","query":{"item":"book"}}' >sample.json
smock render --dir defs --request sample.json orders | jq -c '[.response.status, .response.body.data]'
# [200,"[{\"id\":1,\"item\":\"book\"}]"]
```

Then run both servers, send each the same requests, and compare the
status, the Content-Type and the body, its keys sorted by `jq -S`. This
bash function sends one request to Mockoon on port 3000 and to smock on
port 8080; its arguments are the path and any further curl arguments:

```sh
both() {
  for port in 3000 8080; do
    curl -s -o body.out -w "$port %{http_code} %{content_type} " "${@:2}" "localhost:$port$1"
    jq -cS . body.out 2>/dev/null || echo '(not JSON)'
  done
}
both '/api/v1/users?status=inactive'
both /api/v1/users -H 'X-Api-Key: secret' -d 'name=Alice&role=admin'
both /api/v1/users/
```

```text
3000 200 application/json; charset=utf-8 [{"id":3,"name":"Carol","status":"inactive"}]
8080 200 application/json [{"id":3,"name":"Carol","status":"inactive"}]
3000 201 application/json; charset=utf-8 {"id":"7b379cf7-3cf7-4005-a7c6-e38675c61cbd","name":"Alice"}
8080 403 application/json {"error":"forbidden"}
3000 200 application/json; charset=utf-8 [{"id":1,"name":"Alice","status":"active"},{"id":2,"name":"Bob","status":"active"}]
8080 404 application/json {"error":"no Stub matched"}
```

The last two pairs are differences from the section above: a form body,
which the example's Stubs do not read, and a trailing slash.

Last, run the clients' own tests against smock. The Journal records
every request, and `GET /v1/journal/unmatched` on the Admin API lists
those that no Stub answered, oldest first, each with its Near miss and
the conditions it failed. When a smock just started gets the requests
in the table of [The result](#the-result) and the three `both` calls
above, it lists only the trailing slash, since the CRUD Stub answers
every request for orders:

```sh
curl -s -H "Authorization: Bearer change-me" localhost:9090/v1/journal/unmatched |
  jq -c '.entries[] | [.request.method, .request.target, .nearMiss.stub, [.nearMiss.failed[]?.condition]]'
# ["GET","/api/v1/users/","list-users",["path"]]
```

Without a `baggage` header, it lists the requests that named no Session;
a test that names its Session sees its own
([Verifying calls and unmatched requests](../README.md#verifying-calls-and-unmatched-requests)).

## Running it where Mockoon ran

Each release of smock publishes binaries, an image and a Helm chart,
all under the release's version: its tag without the `v`. Take the
latest release, 0.3.0 or later, listed under
[Releases](https://github.com/hirunefu/smock/releases), and put its
version in place of `<version>` below.

- **On Linux.** The release has the binaries
  `smock-<version>-linux-amd64` and `smock-<version>-linux-arm64`. Each
  needs glibc 2.34 or later and OpenSSL 3 (on Debian and Ubuntu, the
  `libssl3` package, or `libssl3t64` on newer releases):

  ```sh
  curl -fsSL --create-dirs -o bin/smock \
    https://github.com/hirunefu/smock/releases/download/v<version>/smock-<version>-linux-amd64
  chmod +x bin/smock
  SMOCK_ADMIN_TOKEN=change-me bin/smock serve --dir defs
  ```

  `smock serve` needs a token for its Admin API; `--admin-auth off`
  turns the Admin API's authentication off for local use.
- **In Docker**, `ghcr.io/hirunefu/smock:<version>` in place of
  `mockoon/cli`. It is for linux/amd64 and linux/arm64, so docker pulls
  the one for the machine. Mount the definitions directory, readable by
  UID 65532, and map port 3000 to 8080, so that clients keep the port
  they used for Mockoon
  ([Environments told apart by port](#environments-told-apart-by-port)
  covers several environments):

  ```sh
  export SMOCK_ADMIN_TOKEN=change-me
  docker run --rm --read-only -e SMOCK_ADMIN_TOKEN -p 3000:8080 -p 9090:9090 \
    -v "$PWD/defs:/defs:ro" ghcr.io/hirunefu/smock:<version> serve --dir /defs
  ```

- **On Kubernetes.**
  [getting-started-on-gke.md](getting-started-on-gke.md) installs the
  release's chart. The Definition file and its body files go in as
  values. The command reuses that guide's namespace `mocks`, token
  Secret and `$VERSION`, so run it in that guide's shell, in
  `docs/examples/from-mockoon/`, before that guide's clean-up. It
  upgrades that guide's release `smock` to serve the example in place of
  its Definition file:

  ```sh
  helm upgrade --install smock oci://ghcr.io/hirunefu/charts/smock --version "$VERSION" --namespace mocks \
    --set adminAuth.tokenSecret.name=smock-admin-token \
    --set-file 'definitions.configMap.files.users-api\.yaml=defs/users-api.yaml' \
    --set-file 'definitions.configMap.bodyFiles.users\.json=defs/files/users.json' \
    --set-file 'definitions.configMap.bodyFiles.inactive-users\.json=defs/files/inactive-users.json' \
    --wait --timeout 10m
  ```

  After that guide's
  [appendix](getting-started-on-gke.md#appendix-an-unreleased-commit),
  name the chart and the image as its install does instead, with the
  chart's path from here, `../../../charts/smock`.
  Adding body files replaces the Pod. That guide's port-forwards reach
  the old Pod, with the old files, until it stops, and then end, so stop
  them (`kill %1 %2`) and start them again. `localhost:8080/api/v1/users`
  then reaches `users-api`, whose `hosts` lists `localhost`. On
  2026-10-17 the example ran this way on GKE Autopilot, from an image of
  CI's binary and the chart in a checkout. It had no Scenario Stubs and
  no Data bucket then; those were checked later, with a local smock
  only.
  Values hold text only, so binary body files need git-sync or a
  ConfigMap of one's own
  ([charts/smock/README.md](../charts/smock/README.md)).
  With several Mocks, each client must send a Host that its Mock lists,
  and the chart creates one Service for traffic, `smock`, for all of
  them: the other names need Services of their own for the same Pods, or
  clients that set the Host header.
- **Switching clients over.** Point clients at smock's plain port, 8080,
  or keep their port by mapping it as above. Clients of an environment
  with `tlsOptions.enabled` move to the TLS port, 8443, or keep their
  port by mapping it there (`-p 3000:8443` in Docker). Check that the
  Host they send is in the Mock's `hosts`: a `Smock-Mock: …; via=default`
  header on their responses means it is not. A Host that another Mock
  lists shows no such header
  ([Environments told apart by port](#environments-told-apart-by-port)).
  Then read the unmatched requests as in
  [Checking the migration](#checking-the-migration).
- **An unreleased commit.** To run a commit that no release holds yet,
  take CI's binary or build one, as in the
  [appendix](getting-started-on-gke.md#appendix-an-unreleased-commit)
  of getting-started-on-gke.md. An image built there for local use needs
  no registry, so tag it `smock:dev` in place of `"$IMAGE"`, and run it
  as above with `smock:dev` in place of `ghcr.io/hirunefu/smock:<version>`.

## Mapping reference

These tables map each part of a Mockoon environment that has a
counterpart, and name those that have none.

### Environments and routes

| Mockoon | smock |
|---|---|
| Environment | A Mock, best in a Definition file of its own. |
| `name` | The Mock's `name`, best short and without spaces, since Admin API paths and `Smock-Mock` carry it. |
| `lastMigration` | Dropped; a Definition file may give `version: 1`. |
| `port` | `smock serve --port`, 8080 by default, shared by every Mock; environments that clients tell apart only by port need Hosts of their own or one smock each ([Environments told apart by port](#environments-told-apart-by-port)). |
| `hostname` | No counterpart: smock listens on every IPv4 address. |
| `endpointPrefix` | Written into each Stub's path. |
| `headers` | Copied into each Stub's `headers` where clients rely on them, quoted where YAML would read a number or a boolean, and, except Content-Type, into the Mock's `noMatch.headers`. |
| `latency` | Added to each Stub's delay Fault; requests that no Stub matches are not delayed. |
| `cors: true` | An `OPTIONS` Stub, declared last, with the three `Access-Control-Allow-*` headers, replaced and extended by the environment headers. |
| `cors: false` | No `OPTIONS` Stub. |
| `tlsOptions` | Nothing to set: smock also serves HTTPS, on port 8443 (`--tls-port`), with a self-signed certificate for `localhost` and every Host unless `--tls-cert-file` and `--tls-key-file` give a PEM certificate and key (convert a PFX file with `openssl pkcs12`). Client certificates are not checked. |
| `proxyMode` and the other `proxy…` fields | No counterpart; the Mockoon CLI logs the requests it proxied with `"requestProxied":true`. |
| `data` (data buckets) | The top-level `data` of a Definition file: a [Data bucket](definition-files.md#data-buckets) for each, whose `mock` is the environment's Mock ([The CRUD route](#latency-cors-and-the-crud-route)). |
| A bucket's `name` | `name`: 1 to 128 ASCII letters, digits, `_` and `-`, which templates and Stubs use exactly. Mockoon's helpers also find a bucket by its `id`, or by any part of its name, in any case ([Data buckets](#data-buckets)). |
| A bucket's `id`, `uuid` | Dropped: smock names a bucket by its `name`. |
| A bucket's `value` | `json`, or `jsonFile` with a file in `defs/files/`: static JSON, never a template. Save templated content as Mockoon generated it ([Behaviour that differs](#behaviour-that-differs)). |
| A bucket's `documentation` | A YAML comment. |
| `callbacks` | No counterpart. |
| `rootChildren`, `folders` | The order of the Stubs. |
| Route `method` | `method`, in upper case; left out for `all`. |
| Route `endpoint` | `path`, exact or a `pattern` ([Paths and request conditions](#paths-and-request-conditions)). |
| Route `documentation` | A YAML comment. |
| `uuid` | Dropped. |
| `responseMode: null` | Stubs for the responses with rules, then one for the default response. |
| `DISABLE_RULES` | Only the default response, with only the route's method and path as conditions. |
| `FALLBACK` | No Stub for the default response without its rules. |
| `SEQUENTIAL` | A Stub for each response, in order and without its rules, each requiring a state of the route's Scenario and moving it to the next, the last back to `Started` ([Answers that change between requests](#answers-that-change-between-requests)). |
| `RANDOM` | One Stub with every response in `responses`, without their rules. Mockoon has no weights; copies of a response become one response whose `weight` is their number ([Random responses](#random-responses)). |
| Route `type: http` | Stubs, as above. |
| `type: crud` | A [CRUD Stub](definition-files.md#crud-stubs) in the route's place, whose `crud.path` is the prefix and the endpoint, joined ([The CRUD route](#latency-cors-and-the-crud-route)). The responses that the route's rules pick become Stubs before it. Its list takes smock's own parameters. `PUT`, `PATCH` and `DELETE` on the list, and a bucket that is not an array of objects with keys, need ordinary Stubs ([Data buckets](#data-buckets)). |
| `type: ws` | No counterpart. |
| `streamingMode`, `streamingInterval` | No counterpart: they belong to WebSocket routes. |

### Rules

| Mockoon rule | smock request condition |
|---|---|
| `query` | `query: { status: inactive }`; a rule on a nested name such as `filter.name` becomes the parameter's literal name, `query: { "filter[name]": Alice }`. |
| `header` | `headers: { X-Api-Key: secret }`, the name in any case. |
| `body` with a path, on a JSON body | `body: { json: { role: admin } }`, a subset match on JSON bodies, with types compared. With `regex`, a pattern in the value's place, `body: { json: { email: { pattern: '.*@example\.com' } } }`, which also meets a number or a boolean by its text, but never `null`, an object or an array ([Paths and request conditions](#paths-and-request-conditions)). A key named `pattern`, alone in its object, takes a pattern as its value: `{ filter: { pattern: { pattern: 'a\.b' } } }`. |
| `body` with a path, on a form body | `body: { form: { role: admin } }`, which, as in Mockoon, needs the form Content-Type. A nested name such as `user.name` becomes the field's literal name, `form: { "user[name]": Alice }`. A Stub reads one format, so a rule that clients meet with JSON and with forms needs a Stub for each. |
| `body` with a path, on an XML body | `body: { xml: { /user/name: Alice } }`: `user.name._text` becomes `/user/name`, and `user._attributes.id` becomes `/user/@id`. smock ignores namespace prefixes, trims the text, and parses the body whatever its Content-Type ([Paths and request conditions](#paths-and-request-conditions)). `_declaration` and array indexes have no counterpart. |
| `body` on a multipart body | No counterpart: a `pattern` on the whole body. |
| `body` without a path | `body: "<the whole body>"`, or a `pattern`. |
| `params` | Part of the path's `pattern`, widened with `[^/]*` so that it stays within its segment. |
| `path` | `path`, exact or a `pattern`. Mockoon also tests the URL with its query string. |
| `method` | `method`, in upper case. |
| `cookie` | `cookies: { session: abc }`, the name compared exactly. The value is compared as sent, where Mockoon decodes it and strips quotes, and every cookie of a repeated name is tested, where Mockoon reads the first ([Paths and request conditions](#paths-and-request-conditions)). |
| Operator `equals` | The value itself; with the type that clients send in a `json` condition, or as a pattern there, which meets a string, a number or a boolean by its text. On an array, `{ $includes: … }`, since Mockoon's `equals` holds when any element does. |
| Operator `regex` | `{ pattern: … }`, widened to match the whole value: `admin` becomes `.*admin.*`, or `[^/]*admin[^/]*` in a path, and `^0+$` becomes `0+`. On an array, `{ $includes: { pattern: … } }`. |
| Operator `regex_i` | The same, with `(?i)` in front. |
| A `modifier` that starts with `$` (JSONPath) | The same path as nested keys in a `json` condition; JSONPath filters, wildcards and array indexes have no counterpart. |
| `rulesOperator: AND` | All the conditions on one Stub. |
| `rulesOperator: OR` | One Stub per rule. |
| `invert` | `{ $not: … }` around the rule's value or pattern, which, like the inverted rule, also holds when the name or key is absent: `headers: { Authorization: { $not: { pattern: 'Bearer\s+\S+.*' } } }`. An inverted rule on the path, the method, `params` or the whole body as text, or one that must hold for a body of the wrong format, turns the route around: the Stubs of the later responses get the rule's condition and go first, and the inverted response's Stub follows them without it ([Paths and request conditions](#paths-and-request-conditions)). |
| Operator `null` | No single condition: a Stub for each case, each with the response. `{ $exists: false }` for an absent name or key, `""` for an empty value, and in a `json` condition also `null`: the rule query `a` null becomes two Stubs, with `query: { a: { $exists: false } }` and `query: { a: "" }`. A body that does not parse as JSON fails all three, though Mockoon's rule holds for it. Inverted: `{ pattern: "(?s).+" }`, which in a `json` condition meets a non-empty string, a number or a boolean, but not an object or an array. |
| Operator `empty_array` | `[]` in a `json` condition, which meets only an empty array. Inverted: `{ $not: [] }`, which, as in Mockoon, a missing key and a value that is not an array also meet. |
| Operator `array_includes` | `{ $includes: … }`, which holds only for an array: `body: { json: { tags: { $includes: admin } } }`. Mockoon compares the elements as text, so `1` meets `1` and `"1"`; `{ $includes: { pattern: "1" } }` does too. |
| Operator `valid_json_schema` | No counterpart. |
| Target `request_number` | A chain of states of the route's Scenario: a Stub for each of the first requests, each moving the Scenario on, then a Stub for the later ones that requires the last state ([Answers that change between requests](#answers-that-change-between-requests)). Only the Stubs with `moveTo` count. |
| Targets `global_var`, `data_bucket`, `templating` | No counterpart: conditions read the request only, never a Variable or a Data bucket ([Global variables](#global-variables), [Data buckets](#data-buckets)). |

### Responses

| Mockoon | smock |
|---|---|
| `statusCode` | `status`, from 200 to 599. |
| `label` | Part of the Stub's `id`, which is unique in the definition set. |
| `headers` | `headers`, a map from each name to a string, or to an array of strings for several `Set-Cookie` values. Names are compared case-insensitively. |
| `bodyType: INLINE` | `json` or `body`. |
| `body` | `json` for JSON, or `body` for text sent as written; with `template: true` when it uses helpers. |
| The default body, `{}` | `json: {}`. A Stub without a body sends an empty one. |
| `bodyType: FILE`, `filePath` | `bodyFile`, relative to `defs/files/`, with a Content-Type in `headers`. A templated `filePath` becomes one Stub per file. Without `template: true`, a 200 serves byte ranges to a `GET` ([Behaviour that differs](#behaviour-that-differs)). |
| `sendFileAsBody: false` | `Content-Disposition: attachment; filename="<file name>"` in `headers`, if clients need it. |
| `bodyType: DATABUCKET` | `json: "${data.NAME}"`, with `template: true` ([Data buckets](#data-buckets)). |
| `databucketID` | On a CRUD route, `crud.bucket`, the bucket's `name`. With `bodyType: DATABUCKET`, the `NAME` in `${data.NAME}`. |
| `crudKey` | The bucket's `key`. Mockoon's default, `id`, is written out. Nested keys, such as `data.id`, have no counterpart. |
| `disableTemplating` | No `template: true`. |
| `fallbackTo404` | A Stub with the path pattern after the Stubs of the files, with 404, the response's headers and its inline body ([Bodies, headers and templates](#bodies-headers-and-templates)). |
| `latency` | `fault: { delay: { fixed: <ms> } }`, with the environment's latency added. |
| `--enable-random-latency` | `fault: { delay: { uniform: { min: 0, max: <ms> } } }`. |
| `default` | The Stub with only the route's conditions, last among the route's Stubs. |
| `callbacks` | No counterpart. |
| `{{status 404}}` | No counterpart: `status` is never templated. `responses` vary the status, at random ([Random responses](#random-responses)). |

### Template helpers

smock's expressions are described in
[docs/definition-files.md](definition-files.md#templates). Helpers that
are not listed here have no counterpart. Where clients need only a value
of the right kind, take a smock helper that gives one, such as
`${fake.words(3)}` for `{{faker 'commerce.productName'}}`; otherwise
write a fixed value. Leaving the member out changes the body's shape.

| Mockoon | smock |
|---|---|
| `{{urlParam 'id'}}` | `${path[n]}`, the segment counted from 0 after the leading `/`; `${number(path[n])}` where the template has no quotes around it. |
| `{{queryParam 'lang' 'en'}}` | `${query.lang ?? 'en'}` |
| `{{header 'X-Request-Id'}}`, `{{header 'Accept-Language' 'en-US'}}` | `${header.x-request-id ?? ''}`, `${header.accept-language ?? 'en-US'}` |
| `{{body 'user.name'}}`, `{{body '$.items[0].sku'}}` | `${body.user.name ?? ''}`, `${body.items[0].sku ?? ''}`, from JSON bodies only. |
| `{{body}}`, without a path | `${bodyText}` |
| `{{bodyRaw 'items'}}` | `body.items` as the value of `$each` or `$if`, or `${body.items}` alone in a `json` string, which keeps its type. |
| `{{cookie 'session'}}`, `{{cookie 'session' 'none'}}` | `${cookie.session ?? ''}`, `${cookie.session ?? 'none'}`, the value as the client sent it. Mockoon strips one pair of quotes and percent-decodes it, so for `session="a%20b"` it gives `a b`, and smock `"a%20b"`, as for [cookie rules](#paths-and-request-conditions). |
| `{{method}}` | `${method}` |
| `{{faker 'string.uuid'}}`, `{{uuid}}`, `{{guid}}` | `${fake.uuid()}` |
| `{{int 1 100}}`, `{{faker 'number.int' min=1 max=100}}` | `${fake.int(1, 100)}` |
| `{{float 1 100}}`, `{{faker 'number.float' min=1 max=100 fractionDigits=2}}` | `${fake.decimal(1, 100, 2)}`, with a set number of decimals. |
| `{{boolean}}`, `{{faker 'datatype.boolean'}}` | `${fake.bool()}` |
| `{{firstName}}`, `{{lastName}}`, `{{faker 'person.firstName'}}`, `{{faker 'person.lastName'}}` | `${fake.firstName()}`, `${fake.lastName()}` |
| `{{faker 'person.fullName'}}` | `${fake.name()}` |
| `{{email}}`, `{{faker 'internet.email'}}` | `${fake.email()}`, always at `example.com`. |
| `{{faker 'string.alphanumeric' 40}}` | `${fake.hex(40)}`, hex digits only, at most 64. |
| `{{faker 'lorem.word'}}`, `{{faker 'lorem.words' 3}}` | `${fake.word()}`, `${fake.words(3)}` |
| `{{oneOf (array 'a' 'b')}}` | `${fake.pick('a', 'b')}` |
| `{{add a b}}`, `{{subtract a b}}`, `{{multiply a b}}` | `${add(a, b)}`, `${subtract(a, b)}`, `${multiply(a, b)}`, exact in decimal: `add(0.1, 0.2)` gives `0.3`, where Mockoon gives `0.30000000000000004`. Each takes two numbers, so `{{add a b c}}` becomes `${add(add(a, b), c)}`. A number may be a string that is a JSON number, such as `query.page`. |
| `{{divide a b}}` | `${divide(a, b)}`, rounded half to even at 10 decimal places: `divide(10, 3)` gives `3.3333333333`, where Mockoon gives `3.3333333333333335`. A divisor of 0 is an error, where Mockoon skips it. |
| `{{modulo a b}}` | `${modulo(a, b)}`, with the sign of `a`, as in Mockoon. A divisor of 0 is an error, where Mockoon gives an empty text. |
| `{{ceil x}}`, `{{floor x}}`, `{{round x}}` | `${ceil(x)}`, `${floor(x)}`, `${round(x)}`. `round` takes a half away from zero: `round(-2.5)` gives `-3`, where Mockoon's `Math.round` gives `-2`. |
| `{{toFixed x 2}}` | `${toFixed(x, 2)}`, the places a literal from 0 to 18, rounded half away from zero in decimal: `toFixed(1.005, 2)` gives `1.01`, where Mockoon gives `1.00`. |
| `{{parseInt x}}` | `${parseInt(x)}`, of a number or a string that is one: `parseInt('12px')` is an error, where Mockoon gives `12`. |
| `{{concat a b}}`, `{{uppercase s}}`, `{{lowercase s}}`, `{{padStart s 6 '0'}}`, `{{padEnd s 6}}`, `{{substr s 0 3}}`, `{{indexOf s 'x'}}`, `{{includes s 'x'}}`, `{{len x}}` | `${concat(a, b)}`, `${uppercase(s)}`, `${lowercase(s)}`, `${padStart(s, 6, '0')}`, `${padEnd(s, 6)}`, `${substr(s, 0, 3)}`, `${indexOf(s, 'x')}`, `${includes(s, 'x')}`, `${len(x)}`. They count code points, where Mockoon counts UTF-16 units ([Behaviour that differs](#behaviour-that-differs)). `uppercase` and `lowercase` map one code point to one, so `uppercase('straße')` gives `STRAßE`, where Mockoon gives `STRASSE`. smock also has `trim`. |
| `{{replace s 'a' 'b'}}`, `{{replaceAll s 'a' 'b'}}` | `${replace(s, 'a', 'b')}`, `${replaceAll(s, 'a', 'b')}`, with the replacement taken as it is, where Mockoon expands `$&` and `$$` in it. |
| `{{split s ','}}` | `${split(s, ',')}`, an array, for `$each` or a step such as `[0]`. An empty separator splits into code points, where Mockoon splits at spaces, and an empty text gives `[""]`, where Mockoon gives an empty text. |
| `{{join array ', '}}` | `${join(array, ', ')}`. The separator must be given, where Mockoon takes `, ` by default, and a value that is not an array is an error, where Mockoon gives it back unchanged. |
| `{{base64 s}}`, `{{base64url s}}`, `{{base64Decode s}}`, `{{base64urlDecode s}}` | `${base64(s)}`, `${base64url(s)}`, `${base64Decode(s)}`, `${base64urlDecode(s)}`. A block, such as `{{#base64}}id-{{body 'id'}}{{/base64}}`, becomes `${base64(concat('id-', body.id))}`. The decoders are strict: each takes its own alphabet only, and a character outside it, or padding that is not whole or not at the end, is an error, where Mockoon skips such characters and stops at the first `=`. smock also has `urlEncode` and `urlDecode`. |
| `{{jwtPayload token 'sub'}}`, `{{jwtHeader token 'alg'}}` | `${jwtPayload(token).sub ?? ''}`, `${jwtHeader(token).alg ?? ''}`: a step reads a claim, at any depth. Neither tool checks the signature. A value that is not a token is missing, so `?? ''` gives Mockoon's empty text. smock removes `Bearer` in any case, where Mockoon's `jwtHeader` gives an empty text for `bearer …`. |
| `{{now}}` | `${now()}`, in UTC with `Z`, where Mockoon writes local time with an offset, such as `+00:00` ([Behaviour that differs](#behaviour-that-differs)). |
| `{{now 'yyyy-MM-dd'}}` | `${now('yyyy-MM-dd')}`, in UTC, with the same date-fns tokens, except that `YYYY`, `YY`, `Y`, `DD` and `D` fail when the files load. |
| `{{dateFormat d 'yyyy-MM-dd'}}` | `${dateFormat(d, 'yyyy-MM-dd')}`, in UTC, or at a fixed offset with a third argument, such as `'+09:00'`. A date that smock does not read is missing. |
| `{{dateTimeShift date=d months=1}}`, `{{dateTimeShift days=1 format='yyyy-MM-dd'}}` | `${dateTimeShift(d, 'P1M')}`, `${dateFormat(dateTimeShift(now(), 'P1D'), 'yyyy-MM-dd')}`: an ISO 8601 duration in place of the named amounts, and the result in RFC 3339, for `dateFormat` to format. A month shift stops at the end of the month, where Mockoon's rolls over. |
| `{{#repeat 3}}` | `{ $each: "range(1, 3)", as: i, do: … }`, in `json` only. |
| `{{#each}}` | `$each` over an array, or the values of a query parameter, a header or a cookie, in `json` only. A literal `(array …)` of strings becomes `split(…)` of one text; other literal arrays are written out ([Bodies, headers and templates](#bodies-headers-and-templates)). |
| `{{#if}}`, `{{#switch}}` | `$if`, which compares with `==` or `!=` against a literal, in `json` only: one for each member that the block wraps, and `(eq (queryParam 'c') 'a')` becomes `query.c == 'a'`. |
| `{{setVar}}`, `{{getVar}}` | No counterpart: the expression, written wherever the variable is read. |
| `{{setGlobalVar 'user' (body 'name')}}` | `variables: { user: "${body.name ?? ''}" }` on the Stub, written when the Stub matches, never from a template ([Global variables](#global-variables)). |
| `{{getGlobalVar 'user'}}`, `{{getGlobalVar 'user' 'address.city'}}` | `${vars.user ?? ''}`, `${vars.user.address.city ?? ''}`, a path as steps. |
| `{{getEnvVar 'REGION'}}`, `{{getEnvVar 'REGION' 'local'}}` | `${env.REGION ?? ''}`, `${env.REGION ?? 'local'}`, with `smock serve --template-env REGION`. Mockoon reads `MOCKOON_REGION`, and smock `REGION`, once, at startup, and only when `--template-env` lists it ([Environment variables](definition-files.md#environment-variables)). |
| `{{{x}}}` | `${raw(x)}`, in text templates. |
| `{{stringify x}}` | `${json(x)}` in text templates; in `json`, a string that is exactly `${x}`. |
| `{{data 'orders' '0.item'}}`, `{{data 'orders' '$.[0].item'}}`, `{{data 'orders'}}` | `${data.orders[0].item}`, `${data.orders}`: the bucket named exactly, and a dot path or a JSONPath as steps. An object or an array needs `${json(data.orders)}` in a text template; in `json`, a string that is exactly `${data.orders}` keeps it ([Data buckets](#data-buckets)). |
| `{{dataRaw 'orders'}}` | `data.orders` as the value of `$each` or `$if`, or `${data.orders}` alone in a `json` string. |
| `{{setData 'push' 'cart' '' (bodyRaw)}}` and the other operations | A write of the Stub's `dataWrites`, made when the Stub matches: `{ op: append, bucket: cart, value: "${body}" }` ([Data buckets](#data-buckets) maps each operation). |

### Running and operating

| Mockoon | smock |
|---|---|
| `mockoon-cli start --data env.json` | `smock serve --dir defs`, with the Admin API token in `SMOCK_ADMIN_TOKEN`. |
| `mockoon-cli start --data openapi.yaml`, which serves an OpenAPI document | `smock import-openapi` once, then `smock serve`: smock never reads OpenAPI when it serves ([Importing OpenAPI](importing-openapi.md)). |
| `--watch` | Built in: smock reloads changed files without a restart, and keeps serving the current set when the new one is invalid. |
| `mockoon-cli validate` | `smock check defs` |
| `--disable-routes` | Remove the Stubs, or move them out of the definitions directory. |
| `--faker-seed` | `--seed`, or `fault.seed` on a Stub. |
| `--max-request-body-size` | `--body-limit`, 10 MiB by default. |
| `--log-transaction` and the logs | The Journal: `POST /v1/journal/query` and `GET /v1/journal/unmatched`. |
| The admin API, under `/mockoon-admin` | The Admin API, on its own port, 9090 by default. Mockoon 9.9.0's admin API needs a bearer token too: `--admin-api-token` sets it, or Mockoon logs the one it generates at startup. |
| `PURGE /mockoon-admin/state` | `POST /v1/reset` with `{"scope":"all"}`, which clears the Ephemeral Stubs, the Journal, every Scenario state, every Variable and every copy of a Data bucket, so that sequences, request counts, global variables and data buckets start over. |
| `PURGE /mockoon-admin/data-buckets` | `POST /v1/reset`, which drops the copies of Data buckets in its scope, with the rest of the scope's state, or a `DELETE` on `/v1/mocks/{mock}/data/{bucket}` for each bucket of the calling Session ([Data buckets](#data-buckets)). |
| `GET /mockoon-admin/data-buckets`, `GET /mockoon-admin/data-buckets/{id}` | `GET /v1/mocks/{mock}/data` lists the Mock's buckets, and `GET /v1/mocks/{mock}/data/{bucket}` reads the value that the calling Session reads. A `PUT` there sets the Session's copy, which Mockoon cannot do. |
| `/mockoon-admin/global-vars` | `GET /v1/mocks/{mock}/variables` lists the calling Session's Variables, and `PUT` and `DELETE` on `/v1/mocks/{mock}/variables/{name}` set and delete one ([Global variables](#global-variables)). |
| `PURGE /mockoon-admin/global-vars` | `POST /v1/reset`, which also clears Ephemeral Stubs, Journal entries, Scenario states and copies of Data buckets, or a `DELETE` for each Variable. |
| `--env-vars-prefix` | `--template-env`, which lists each name in full; there is no prefix. |
| `/mockoon-admin/env-vars` | No counterpart: smock reads the variables that `--template-env` lists once, at startup. |
| `PUT /mockoon-admin/environment` | Edit the files; smock reloads them. |
| The `mockoon/cli` image | `ghcr.io/hirunefu/smock:<version>`, from a release. |
| `import` | `smock import-openapi <document> --mock <name> --output <file>`, from the same OpenAPI document ([Importing OpenAPI](importing-openapi.md#notes-for-mockoon-users)). |
| `export` | No counterpart. |
