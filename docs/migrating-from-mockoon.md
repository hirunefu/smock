# Migrating from Mockoon

This guide turns a Mockoon environment into Definition files for smock.
It is written for Mockoon 9.x environment files, whose `lastMigration` is
33, and its statements about Mockoon were checked against Mockoon 9.9.0,
its documentation and its source on 2026-10-17. It starts with what smock
does not do, so that a reader whose environments depend on one of those
features can stop there. A worked example then translates one
environment step by step, and a reference at the end maps every part of
an environment that has a counterpart:

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

## What smock does not do

These Mockoon features have no counterpart in smock. Where something
covers part of the need, the item says what.

- **Proxy mode and recording.** smock never forwards a request to the
  real service and never records traffic: every answer comes from a
  Stub, and a request that no Stub matches gets a 404.
- **Data buckets and CRUD routes.** smock keeps no data, so a `POST` does
  not change what a later `GET` returns. A Stub can serve a bucket's
  initial value, and a test can change answers for itself with Ephemeral
  Stubs, as [the CRUD route](#latency-cors-and-the-crud-route) of the
  example shows.
- **Answers that depend on earlier requests.** The `RANDOM` and
  `SEQUENTIAL` response modes, `request_number` rules, and global
  variables have no counterpart. `fake.pick(…)` varies a value, a
  Fault's `probability` varies failures, and a test changes the answer
  between its calls by adding or deleting Ephemeral Stubs in its
  Session.
- **Callbacks.** smock never sends a request of its own.
- **WebSockets.** smock serves HTTP/1.1 and HTTPS. It can stream
  Server-Sent Events, which only a client written for them reads.
- **Request conditions beyond equality and patterns.** Negation
  (`invert`), the `null`, `empty_array`, `array_includes` and
  `valid_json_schema` operators, and conditions on form fields, XML or
  cookies by name have no direct counterpart.
  [Rules](#rules) gives the workarounds that exist.
- **Most Handlebars helpers.** smock's templates are not Handlebars, and
  have no arithmetic, string functions, date formats, JWT decoding,
  cookie reading, local or environment variables, or faker locales.
  [Template helpers](#template-helpers) maps the helpers that have a
  counterpart.
- **A port or a path prefix per environment.** One smock serves all its
  Mocks on one plain port and one TLS port, and tells them apart by the
  request's Host.
- **A body for unmatched requests.** A Mock sets only the status of its
  no-match response.
- **Response limits.** A response's status is from 200 to 599, and body
  files are always sent whole, without Range requests.
- **OpenAPI import and export, and a GUI.** The translation is done by
  hand, and Definition files are edited as text. Editors can check them
  against the JSON Schema
  ([editor support](definition-files.md#editor-support)).
- **Windows and macOS.** smock runs on Linux, on amd64 and arm64, or in a
  Linux container.
- **A published image.** No release exists yet, so there is nothing to
  pull in place of `mockoon/cli`.
  [Running it where Mockoon ran](#running-it-where-mockoon-ran) says how
  to build one.

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
- A Stub pairs request conditions with one response. Each response of a
  Mockoon route becomes a Stub of its own, whose conditions are the
  route's method and path plus the response's rules.
- The first Stub that matches a request answers it. Stubs are tried in
  the order they are declared, unless `priority` reorders them, so the
  order of the routes, and of the responses within each route, carries
  over.
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
`Content-Type: application/json`, and four routes:

| Route | Responses, in order | Rules |
|---|---|---|
| `GET users` | 200 with the file `users.json` and 300 ms of latency (the default); 200 with the file `inactive-users.json` | On the second: query `status` equals `inactive`. |
| `GET users/:id` | 200 with an inline template (the default); 404 | On the 404: params `id` regex `^0+$`. |
| `POST users` | 201 with an inline template; 403 (the default) | On the 201: header `X-Api-Key` equals `secret`, AND body `role` equals `admin`. |
| CRUD `orders` | The data bucket `orders`, `[{"id":1,"item":"book"},{"id":2,"item":"pen"}]` | None. |

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
  [What smock does not do](#what-smock-does-not-do). Here only the CRUD
  route is affected, and it keeps its read
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

The environment's `port` and `hostname` have no place in the file. smock
listens on every IPv4 address (`0.0.0.0`), on the port that
`smock serve --port` gives, 8080 by default. Mockoon's `hostname` is the
address Mockoon listens on
([listening hostname](https://mockoon.com/docs/latest/server-configuration/listening-hostname/)),
and has no counterpart. Environments that clients tell apart only by
port, such as `localhost:3000` and `localhost:3001`, need distinct Hosts
or one smock each.

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
- `RANDOM` and `SEQUENTIAL` have no counterpart.

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
default. The query rule of `GET users` becomes
`query: { status: inactive }`, and the two AND rules of `POST users`
become `headers: { X-Api-Key: secret }` and
`body: { json: { role: admin } }` on one Stub.

Three things need care when translating rules; [Rules](#rules) maps
every kind:

- **A Mockoon regex matches anywhere in the value; a smock pattern
  matches the whole value.** `^0+$` drops its anchors, and `admin`
  becomes `.*admin.*`. RE2 has no lookaround and no backreferences, and
  smock supports no `\p{…}` classes.
- **Mockoon's `equals` compares text; a `json` condition compares
  types.** The rule body `count` equals `1` holds for `{"count":1}` and
  for `{"count":"1"}`, but `{ json: { count: 1 } }` only for the first,
  so write values with the type that clients send. An array that
  contains the value meets a Mockoon `equals` rule, while a `json` array
  needs every element, in order; a `pattern` on the body can test for
  "contains".
- **Mockoon reads JSON, form, multipart and XML bodies; a `json`
  condition reads JSON only.** A form field can be matched only by a
  pattern on the whole body
  ([Behaviour that differs](#behaviour-that-differs)).

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
- **Quoting.** In block style, as above, `${…}` needs no quotes. In a
  flow mapping, `{ id: ${path[3]} }` fails with
  `expected , or } in a flow mapping`; write `{ id: "${path[3]}" }`. A
  comma ends a value there too, so quote an expression that has one,
  such as `{ $each: "range(1, 3)", as: i, do: "${i}" }`.
- **Headers.** Mockoon sends the environment's headers with every
  response, and a response's own headers replace those of the same name.
  smock has no environment headers: copy the ones that clients rely on
  into each Stub's `headers`. Here that is only
  `Content-Type: application/json`, which a `json` body gets by itself
  and the two body-file Stubs set. A key that a Mockoon response lists
  more than once, such as `Set-Cookie`, becomes one name with an array of
  its values, in order:

  ```yaml
  headers:
    Set-Cookie:
      - session=abc; Path=/; HttpOnly
      - theme=dark; Path=/
  ```
- **Empty bodies.** A new Mockoon response has the body `{}`. A Stub
  writes that as `json: {}`, since a Stub without a body sends an empty
  one.
- **Files.** A `FILE` body goes into `defs/files/`, and the Stub names it
  in `bodyFile`, relative to `files/`. Mockoon derives the Content-Type
  from the file's extension and smock does not, so set it. With
  Mockoon's default `sendFileAsBody: false`, Mockoon also sends
  `Content-Disposition: attachment` with the file's name: add that header
  if clients need it (the example's files have `sendFileAsBody` set to
  true). A body file is a template only with `template: true`, and must
  then be UTF-8. A templated file path, Range requests and
  `fallbackTo404` have no counterpart: a missing body file makes the
  definition set invalid, which `smock check` reports
  ([file serving](https://mockoon.com/docs/latest/response-configuration/file-serving/)).
- **Data buckets.** A `DATABUCKET` body becomes the bucket's value,
  written as `json`.

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
  ([CORS](https://mockoon.com/docs/latest/server-configuration/cors/)).
  The Stub `preflight` does the same. It comes last, so that it is not
  named as the Near miss of requests that other Stubs nearly match: on a
  tie in failed conditions, the Near miss is the Stub tried first.
  Mockoon adds CORS headers to other responses only when they are among
  the environment headers; copy them into the Stubs in that case.
- **The CRUD route.** smock keeps no data, so `list-orders` serves the
  bucket's initial value, with the `X-Total-Count` and
  `X-Filtered-Count` headers that Mockoon sends. Mockoon also answers
  `GET /api/v1/orders/1` and `/2` from the bucket; if clients read single
  orders, add a Stub for each, such as
  `request: { method: GET, path: /api/v1/orders/1 }` with
  `json: { id: 1, item: book }`. A test that needs the order it creates
  adds Ephemeral Stubs for its own Session through the Admin API, and
  smock tries those before the file's Stubs. The README's
  [Sessions and Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs)
  describes them:

  ```sh
  curl -H "Authorization: Bearer change-me" -H "baggage: smock-session=checkout-42" \
    -d '{"request":{"method":"POST","path":"/api/v1/orders"},"response":{"status":201,"json":{"id":3,"item":"pencil"}}}' \
    localhost:9090/v1/mocks/users-api/stubs
  curl -H "baggage: smock-session=checkout-42" -d '{"item":"pencil"}' localhost:8080/api/v1/orders   # 201
  curl -d '{"item":"pencil"}' localhost:8080/api/v1/orders                                          # 404
  ```

### The result

The whole Definition file:

```yaml
# The Mockoon environment ../mockoon/users-api.json as a Definition file.
# Each group of Stubs is one Mockoon route, in the environment's order.
mocks:
  - name: users-api
    hosts: [localhost, users-api]

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

  # orders: a CRUD route on the data bucket "orders". Only the list is
  # kept, with the bucket's initial value.
  - id: list-orders
    mock: users-api
    request: { method: GET, path: /api/v1/orders }
    response:
      status: 200
      headers: { X-Total-Count: "2", X-Filtered-Count: "2" }
      json: [{ id: 1, item: book }, { id: 2, item: pen }]

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
| `GET /api/v1/orders/1` | 200, `{"id":1,"item":"book"}` | 404, unless a Stub for it is added. |
| `POST /api/v1/orders`, then `GET /api/v1/orders/3` | 201, then 200 with the new order | 404 and 404, unless the test adds Ephemeral Stubs. |

Mockoon's JSON responses, and its `OPTIONS` answer, carry
`Content-Type: application/json; charset=utf-8`; smock's JSON responses
carry `application/json`, and its `OPTIONS` answer none.

## Behaviour that differs

Even a faithful translation answers some requests differently. These
differences were checked against Mockoon CLI 9.9.0 on 2026-10-17, most
of them by sending the same requests to both servers, with the example
or with small environments made to test them:

- **Paths.** Mockoon matches paths case-insensitively, accepts a trailing
  slash and merges repeated slashes. smock compares the decoded path
  exactly, so `GET /API/V1/USERS` and `GET /api/v1/users/` reach
  `list-users` in Mockoon and get 404 from smock. Where clients rely on
  that, use a pattern such as `(?i)/api/v1/users/?`.
- **Request bodies.** Mockoon parses JSON, form, multipart and XML bodies
  by their Content-Type before its rules read them
  ([supported body formats](https://mockoon.com/docs/latest/requests/supported-body-formats/)).
  A `json` condition parses the body as JSON whatever its Content-Type,
  and nothing else. So the form `name=Alice&role=admin`, sent with the
  key to `POST /api/v1/users`, gets 201 from Mockoon and 403 from smock,
  and the same JSON without a Content-Type gets 403 from Mockoon and 201
  from smock. In a template, `${body.x}` reads JSON bodies only.
- **Content-Type.** For a configured `application/json`, Mockoon sends
  `application/json; charset=utf-8`, and with none configured it sends
  `text/html; charset=utf-8`. smock sends the Content-Type exactly as the
  Stub gives it; without one, a `json` body gets `application/json`, and
  other bodies get none.
- **Body bytes.** Mockoon sends an inline body with the spacing it was
  written with. smock writes `json` compactly, numbers in their shortest
  form (`9.90` as `9.9`). Compare bodies after `jq -S`, or write the body
  as `body` text where the exact bytes matter.
- **Escaping.** Mockoon's `body` and `queryParam` helpers insert values
  as they are, so `GET /api/v1/users/7?lang=a%22b` makes the example's
  body invalid JSON in Mockoon. Its other values, `urlParam` and
  `header` among them, are escaped for HTML: `GET /api/v1/users/a%22b`
  answers `"id": "a&quot;b"`. smock escapes every inserted value for the
  response's Content-Type, and in `json` always as JSON, so it answers
  `"lang":"a\"b"` and `"id":"a\"b"`; it escapes for HTML only in HTML
  and XML responses.
- **Unmatched requests.** Mockoon answers a request that no route takes
  with 404 and the `text/html` page "Cannot GET /path". smock answers
  with the Mock's `noMatch.status`, 404 by default, the body
  `{"error":"no Stub matched"}` and a header such as
  `Smock-Near-Miss: list-users; failed=path`.
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
  for a request with 500 and `{"error":"template failed",…}`.
- **Request size.** Mockoon accepts request bodies up to 100 MB by
  default; smock accepts up to 10 MiB (`--body-limit`), and answers
  longer ones with 413.
- **Fake data.** smock draws names and words from built-in lists of ASCII
  names and English words, with no locale. `fault.seed` on a Stub
  repeats them from run to run, and so does `--seed` for the same
  requests in the same order, as `--faker-seed` does in Mockoon.
- **Logs.** The Mockoon CLI logs every request. smock logs none, and
  records them in the Journal instead.

## Checking the migration

`smock check` reads a definitions directory as `smock serve` would, and
prints every problem with its file and a JSON Pointer. It also warns
about a Stub that can never match because an earlier one always matches
first, which often means that responses were written in the wrong order:

```sh
smock check defs   # prints nothing and exits with 0 for the example
```

In CI, run it as a step that fails the build: `- run: smock check defs`.

`smock render` shows, without a server, what one Stub answers to a
sample request, and which of the Stub's conditions the sample fails. The
sample is JSON, `{method, path, query, headers, body}`, with the path and
the query values decoded, and `--seed` makes the fake data repeatable:

```sh
echo '{"method":"GET","path":"/api/v1/users/42","query":{"lang":"ja"}}' >sample.json
smock render --dir defs --request sample.json --seed 7 get-user |
  jq -c '[.response.status, .response.body.data, .failed]'
# [200,"{\"id\":\"42\",\"name\":\"Sebastian Garcia\",\"lang\":\"ja\"}",[]]
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

The last two pairs are differences from the section above, a form body
and a trailing slash.

Last, run the clients' own tests against smock. The Journal records
every request, and `GET /v1/journal/unmatched` on the Admin API lists
those that no Stub answered, oldest first, each with its Near miss and
the conditions it failed. When a smock just started gets the requests
in the table of [The result](#the-result) and the three `both` calls
above, it lists the three requests for orders that only Mockoon's CRUD
route answers, and the trailing slash:

```sh
curl -s -H "Authorization: Bearer change-me" localhost:9090/v1/journal/unmatched |
  jq -c '.entries[] | [.request.method, .request.target, .nearMiss.stub, [.nearMiss.failed[]?.condition]]'
# ["GET","/api/v1/orders/1","list-users",["path"]]
# ["POST","/api/v1/orders","create-user-forbidden",["path"]]
# ["GET","/api/v1/orders/3","list-users",["path"]]
# ["GET","/api/v1/users/","list-users",["path"]]
```

Without a `baggage` header, it lists the requests that named no Session;
a test that names its Session sees its own
([Verifying calls and unmatched requests](../README.md#verifying-calls-and-unmatched-requests)).

## Running it where Mockoon ran

No release of smock exists yet, so there is no binary to download from a
release and no image to pull. Until there is:

- **On Linux.** CI keeps the binaries `smock-linux-amd64` and
  `smock-linux-arm64` for seven days after each push to `main`, and
  downloading them needs read access to the repository. Each needs glibc
  2.34 or later and OpenSSL 3 (on Debian and Ubuntu, the `libssl3`
  package, or `libssl3t64` on newer releases):

  ```sh
  gh run list -R hirunefu/smock --workflow CI --branch main --event push --status success --limit 1 --json databaseId
  gh run download <run-id> -R hirunefu/smock -n smock-linux-amd64 --dir bin   # writes bin/smock
  chmod +x bin/smock
  SMOCK_ADMIN_TOKEN=change-me bin/smock serve --dir defs
  ```

  `smock serve` needs a token for its Admin API; `--admin-auth off`
  turns the Admin API's authentication off for local use.
- **In Docker**, in place of `mockoon/cli`.
  [Get the smock binary](getting-started-on-gke.md#get-the-smock-binary)
  and [Build the image](getting-started-on-gke.md#build-the-image), in
  getting-started-on-gke.md, build an image from CI's linux/amd64 binary
  in a checkout; the same steps with `smock-linux-arm64` and
  `--platform linux/arm64` give one for an Arm machine. An image for
  local use needs no registry, so tag it `smock:dev` in place of
  `"$IMAGE:$TAG"`. Mount the definitions directory, readable by UID
  65532, and map port 3000 to 8080, so that clients keep the port they
  used for Mockoon:

  ```sh
  export SMOCK_ADMIN_TOKEN=change-me
  docker run --rm --read-only -e SMOCK_ADMIN_TOKEN -p 3000:8080 -p 9090:9090 \
    -v "$PWD/defs:/defs:ro" smock:dev serve --dir /defs
  ```

- **On Kubernetes.**
  [getting-started-on-gke.md](getting-started-on-gke.md) installs the
  chart from the checkout. The Definition file and its body files go in
  as values. The command reuses that guide's namespace `mocks`, token
  Secret and image (`$IMAGE` and `$TAG`), so run it in that guide's
  shell, at the repository's root, before that guide's clean-up. It
  upgrades that guide's release `smock` to serve the example in place of
  its Definition file:

  ```sh
  helm upgrade --install smock charts/smock --namespace mocks \
    --set image.repository="$IMAGE" --set image.tag="$TAG" \
    --set adminAuth.tokenSecret.name=smock-admin-token \
    --set-file 'definitions.configMap.files.users-api\.yaml=docs/examples/from-mockoon/defs/users-api.yaml' \
    --set-file 'definitions.configMap.bodyFiles.users\.json=docs/examples/from-mockoon/defs/files/users.json' \
    --set-file 'definitions.configMap.bodyFiles.inactive-users\.json=docs/examples/from-mockoon/defs/files/inactive-users.json' \
    --wait --timeout 10m
  ```

  Adding body files replaces the Pod. That guide's port-forwards reach
  the old Pod, with the old files, until it stops, and then end, so stop
  them (`kill %1 %2`) and start them again. `localhost:8080/api/v1/users`
  then reaches `users-api`, whose `hosts` lists `localhost`. This ran on
  GKE Autopilot on 2026-10-17.
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
  header on their responses means it is not. Then read the unmatched
  requests as in [Checking the migration](#checking-the-migration).

## Mapping reference

These tables map each part of a Mockoon environment that has a
counterpart, and name those that have none.

### Environments and routes

| Mockoon | smock |
|---|---|
| Environment | A Mock, best in a Definition file of its own. |
| `name` | The Mock's `name`. |
| `lastMigration` | Dropped; a Definition file may give `version: 1`. |
| `port` | `smock serve --port`, 8080 by default, shared by every Mock; one smock per port when clients tell environments apart only by port. |
| `hostname` | No counterpart: smock listens on every IPv4 address. |
| `endpointPrefix` | Written into each Stub's path. |
| `headers` | Copied into each Stub's `headers` where clients rely on them. |
| `latency` | Added to each Stub's delay Fault; requests that no Stub matches are not delayed. |
| `cors: true` | An `OPTIONS` Stub with the three `Access-Control-Allow-*` headers, declared last. |
| `cors: false` | No `OPTIONS` Stub. |
| `tlsOptions` | Nothing to set: smock also serves HTTPS, on port 8443 (`--tls-port`), with a self-signed certificate for `localhost` and every Host unless `--tls-cert-file` and `--tls-key-file` give a PEM certificate and key (convert a PFX file with `openssl pkcs12`). Client certificates are not checked. |
| `proxyMode` and the other `proxy…` fields | No counterpart. |
| `data` (data buckets) | No counterpart: a bucket's value goes into a Stub as `json`. |
| `callbacks` | No counterpart. |
| `rootChildren`, `folders` | The order of the Stubs. |
| Route `method` | `method`, in upper case; left out for `all`. |
| Route `endpoint` | `path`, exact or a `pattern` ([Paths and request conditions](#paths-and-request-conditions)). |
| Route `documentation` | A YAML comment. |
| `uuid` | Dropped. |
| `responseMode: null` | Stubs for the responses with rules, then one for the default response. |
| `DISABLE_RULES` | Only the default response, with only the route's method and path as conditions. |
| `FALLBACK` | No Stub for the default response without its rules. |
| `RANDOM`, `SEQUENTIAL` | No counterpart. |
| Route `type: http` | Stubs, as above. |
| `type: crud` | Stubs for the reads; Ephemeral Stubs for a test's own changes. |
| `type: ws` | No counterpart. |
| `streamingMode`, `streamingInterval` | No counterpart: they belong to WebSocket routes. |

### Rules

| Mockoon rule | smock request condition |
|---|---|
| `query` | `query: { status: inactive }`; a rule on a nested name such as `filter.name` becomes the parameter's literal name, `query: { "filter[name]": Alice }`. |
| `header` | `headers: { X-Api-Key: secret }`, the name in any case. |
| `body` with a path | `body: { json: { role: admin } }`, a subset match on JSON bodies, with types compared. |
| `body` without a path | `body: "<the whole body>"`, or a `pattern`. |
| `params` | Part of the path's `pattern`. |
| `path` | `path`, exact or a `pattern`. Mockoon also tests the URL with its query string. |
| `method` | `method`, in upper case. |
| `cookie` | A pattern on the Cookie header: `headers: { Cookie: { pattern: "(.*; )?session=abc(;.*)?" } }`. |
| Operator `equals` | The value itself; with the type that clients send in a `json` condition. |
| Operator `regex` | `{ pattern: … }`, widened to match the whole value: `admin` becomes `.*admin.*`, and `^0+$` becomes `0+`. |
| Operator `regex_i` | The same, with `(?i)` in front. |
| A `modifier` that starts with `$` (JSONPath) | The same path as nested keys in a `json` condition; JSONPath filters and wildcards have no counterpart. |
| `rulesOperator: AND` | All the conditions on one Stub. |
| `rulesOperator: OR` | One Stub per rule. |
| `invert` | No counterpart: put a Stub for the opposite case before the general one. |
| Operators `null`, `empty_array`, `array_includes`, `valid_json_schema` | No counterpart. |
| Targets `request_number`, `global_var`, `data_bucket`, `templating` | No counterpart. |

### Responses

| Mockoon | smock |
|---|---|
| `statusCode` | `status`, from 200 to 599. |
| `label` | Part of the Stub's `id`, which is unique in the definition set. |
| `headers` | `headers`, a map from each name to a string, or to an array of strings for a key the response repeats, such as `Set-Cookie`. Names are compared case-insensitively. |
| `bodyType: INLINE` | `json` or `body`. |
| `body` | `json` for JSON, or `body` for text sent as written; with `template: true` when it uses helpers. |
| The default body, `{}` | `json: {}`. A Stub without a body sends an empty one. |
| `bodyType: FILE`, `filePath` | `bodyFile`, relative to `defs/files/`, with a Content-Type in `headers`. |
| `sendFileAsBody: false` | `Content-Disposition: attachment; filename="<file name>"` in `headers`, if clients need it. |
| `bodyType: DATABUCKET` | The bucket's value as `json`. |
| `databucketID`, `crudKey` | No counterpart; see `bodyType: DATABUCKET` and `type: crud`. |
| `disableTemplating` | No `template: true`. |
| `fallbackTo404` | No counterpart: a missing body file makes the definition set invalid. |
| `latency` | `fault: { delay: { fixed: <ms> } }`, with the environment's latency added. |
| `--enable-random-latency` | `fault: { delay: { uniform: { min: 0, max: <ms> } } }`. |
| `default` | The Stub with only the route's conditions, last among the route's Stubs. |
| `callbacks` | No counterpart. |
| `{{status 404}}` | No counterpart: `status` is never templated. |

### Template helpers

smock's expressions are described in
[docs/definition-files.md](definition-files.md#templates). Helpers that
are not listed here have no counterpart.

| Mockoon | smock |
|---|---|
| `{{urlParam 'id'}}` | `${path[n]}`, the segment counted from 0 after the leading `/`. |
| `{{queryParam 'lang' 'en'}}` | `${query.lang ?? 'en'}` |
| `{{header 'X-Request-Id'}}` | `${header.x-request-id ?? ''}` |
| `{{body 'user.name'}}` | `${body.user.name ?? ''}`, from JSON bodies only. |
| `{{body}}`, without a path | `${bodyText}` |
| `{{bodyRaw 'items'}}` | `body.items` as the value of `$each` or `$if`, or `${body.items}` alone in a `json` string, which keeps its type. |
| `{{method}}` | `${method}` |
| `{{faker 'string.uuid'}}`, `{{uuid}}`, `{{guid}}` | `${fake.uuid()}` |
| `{{int 1 100}}` | `${fake.int(1, 100)}` |
| `{{float 1 100}}` | `${fake.decimal(1, 100, 2)}`, with a set number of decimals. |
| `{{boolean}}` | `${fake.bool()}` |
| `{{firstName}}`, `{{lastName}}` | `${fake.firstName()}`, `${fake.lastName()}` |
| `{{faker 'person.fullName'}}` | `${fake.name()}` |
| `{{email}}` | `${fake.email()}`, always at `example.com`. |
| `{{faker 'lorem.word'}}`, `{{faker 'lorem.words' 3}}` | `${fake.word()}`, `${fake.words(3)}` |
| `{{oneOf (array 'a' 'b')}}` | `${fake.pick('a', 'b')}` |
| `{{now}}` | `${now()}`, in RFC 3339 only. |
| `{{dateTimeShift days=1}}` | `${now(86400)}`, an offset in seconds. |
| `{{#repeat 3}}` | `{ $each: "range(1, 3)", as: i, do: … }`, in `json` only. |
| `{{#each}}` | `$each` over an array, or the values of a query parameter or a header, in `json` only. |
| `{{#if}}`, `{{#switch}}` | `$if`, which compares with `==` or `!=` against a literal, in `json` only. |
| `{{{x}}}` | `${raw(x)}`, in text templates. |
| `{{stringify x}}` | `${json(x)}` in text templates; in `json`, a string that is exactly `${x}`. |

### Running and operating

| Mockoon | smock |
|---|---|
| `mockoon-cli start --data env.json` | `smock serve --dir defs`, with the Admin API token in `SMOCK_ADMIN_TOKEN`. |
| `--watch` | Built in: smock reloads changed files without a restart, and keeps serving the current set when the new one is invalid. |
| `mockoon-cli validate` | `smock check defs` |
| `--disable-routes` | Remove the Stubs, or move them out of the definitions directory. |
| `--faker-seed` | `--seed`, or `fault.seed` on a Stub. |
| `--max-request-body-size` | `--body-limit`, 10 MiB by default. |
| `--log-transaction` and the logs | The Journal: `POST /v1/journal/query` and `GET /v1/journal/unmatched`. |
| The admin API, under `/mockoon-admin` | The Admin API, on its own port, 9090 by default. |
| `PURGE /mockoon-admin/state` | `POST /v1/reset` with `{"scope":"all"}`, which clears the Ephemeral Stubs and the Journal. |
| `PUT /mockoon-admin/environment` | Edit the files; smock reloads them. |
| The `mockoon/cli` image | An image built from CI's binary, until a release publishes one. |
| `import`, `export` | No counterpart. |
