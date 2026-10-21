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

## What smock does not do

These Mockoon features have no counterpart in smock. Where something
covers part of the need, the item says what.

- **Proxy mode and recording.** smock never forwards a request to the
  real service and never records traffic: every answer comes from a
  Stub, and a request that no Stub matches gets a 404. Before switching,
  find the paths that clients reached through the proxy: the Mockoon CLI
  logs each request with `"requestProxied":true` or `false`.
- **Data buckets and CRUD routes.** smock keeps no data, so a `POST` does
  not change what a later `GET` returns. A Stub can serve a bucket's
  initial value, and a test can change answers for itself with Ephemeral
  Stubs, as [the CRUD route](#latency-cors-and-the-crud-route) of the
  example shows.
- **Random answers and global variables.** The `RANDOM` response mode and
  global variables have no counterpart. The `fake.*` helpers, such as
  `fake.pick(…)`, vary a value, a connection Fault's `probability` makes
  some requests fail, though never with a status other than the Stub's,
  and a test changes the answer between its calls by adding or deleting
  Ephemeral Stubs in its Session. `SEQUENTIAL` responses and
  `request_number` rules do carry over, as Scenarios.
  [Answers that change between requests](#answers-that-change-between-requests)
  shows both, and says which answer to keep for the others.
- **Callbacks.** smock never sends a request of its own. A test that
  relied on a callback sends that request to the callback's URL itself,
  and can check in the Journal that the request that fired it arrived.
- **WebSockets.** smock serves HTTP/1.1 and HTTPS. It can stream
  Server-Sent Events, which only a client written for them reads.
- **Schema validation and multipart bodies.** The `valid_json_schema`
  operator has no counterpart, and a multipart body can be matched only
  by a pattern on the whole body. [Rules](#rules) maps the other rules,
  `invert` and rules on cookies, form fields and XML bodies included.
- **Most Handlebars helpers.** smock's templates are not Handlebars, and
  have no arithmetic, array literals, string functions, date formats,
  JWT decoding, cookie reading, local or environment variables, or
  faker locales.
  [Template helpers](#template-helpers) maps the helpers that have a
  counterpart.
- **A port or a path prefix per environment.** One smock serves all its
  Mocks on one plain port and one TLS port, and tells them apart by the
  request's Host.
  [Environments told apart by port](#environments-told-apart-by-port)
  gives the two ways round it.
- **Response limits.** A response's status is from 200 to 599, and body
  files are always sent whole, without Range requests.
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
- A Stub pairs request conditions with one response. Each response of a
  Mockoon route becomes a Stub of its own, whose conditions are the
  route's method and path plus the response's rules.
- The first Stub that matches a request answers it. Stubs are tried in
  the order they are declared, unless `priority` reorders them, so the
  order of the routes, and of the responses within each route, carries
  over.
- A *Scenario* is a named state within a Mock, which starts in the state
  `Started`. A Stub can require one of its states and move it to
  another, so that the same request gets different answers at different
  points of a flow.
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
- `RANDOM` has no counterpart: the same section says which response to
  keep.

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
  such as `{{faker 'number.int' min=5 max=60}}.99`, has no counterpart,
  since smock has no arithmetic; take a helper that gives a number of
  the same kind, such as `${fake.decimal(5, 60, 2)}`.
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

  smock has no array literals, so an `{{#each (array 'SKU-1' 'SKU-2')}}`
  is written out, one element after the other, along with what an
  `{{add @index 1}}` in it computes. `{{setVar}}` has no counterpart:
  write its expression wherever `{{getVar}}` reads the variable.
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
  and must then be UTF-8. Range requests have no counterpart
  ([file serving](https://mockoon.com/docs/latest/response-configuration/file-serving/)).
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
  more conditions of every other Stub, such as
  `DELETE /api/v1/orders/1`, which gets
  `Smock-Near-Miss: preflight; failed=method`. The CORS example in
  [docs/definition-files.md](definition-files.md#when-no-stub-matches)
  gives its preflight Stub a second condition,
  `headers: { Access-Control-Request-Method: { pattern: ".+" } }`, which
  every preflight meets. The 404 for that `DELETE` then names
  `list-users`, which fails its method and path, but an `OPTIONS` request
  without that header, which Mockoon answers, gets 404.

  Mockoon adds CORS headers to other responses, its 404 for a request
  that no route takes included, only when they are among the environment
  headers. In that case, copy them into the Stubs, and into the Mock's
  `noMatch.headers` for its no-match response
  ([Behaviour that differs](#behaviour-that-differs)).
- **The CRUD route.** smock keeps no data, so `list-orders` serves the
  bucket's initial value, with the `X-Total-Count` and
  `X-Filtered-Count` headers that Mockoon sends. Mockoon's list also
  filters, sorts and pages, with `search`, `<field>_eq` and its kin,
  `sort` and `order`, and `page` and `limit`
  ([CRUD routes](https://mockoon.com/docs/latest/api-endpoints/crud-routes/)):
  `GET /api/v1/orders?item_eq=book` answers only the book, with
  `X-Filtered-Count: 1`. A `query` condition ignores the parameters it
  does not list, so `list-orders` answers every such list with the whole
  bucket and `X-Filtered-Count: 2`, without a sign. Give each list that
  clients ask for a Stub of its own, before `list-orders`:

  ```yaml
  - id: list-orders-books
    mock: users-api
    request: { method: GET, path: /api/v1/orders, query: { item_eq: book } }
    response:
      status: 200
      headers: { X-Total-Count: "2", X-Filtered-Count: "1" }
      json: [{ id: 1, item: book }]
  ```

  Mockoon also answers `GET /api/v1/orders/1` and `/2` from the bucket;
  if clients read single orders, add a Stub for each, such as
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
  clears the calling Session's Ephemeral Stubs, Journal entries and
  Scenario states, which sends its Scenarios back to `Started`.
  `{"scope":"all"}` clears every Session's, as
  `PURGE /mockoon-admin/state` starts Mockoon's counts over. A reset
  answers how many states it cleared, in `removed.scenarioStates`.
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
a request, and templates cannot read it. So global variables, data
buckets and CRUD routes still have no counterpart, and neither has
`RANDOM`, which is not state. A `RANDOM` route picks any of its
responses, and a global variable keeps a value that one request sets for
later ones
([global variables](https://mockoon.com/docs/latest/variables/global-variables/)).
Keep a Stub in the file for such a route, so that every client still
gets an answer, and choose the response it sends:

- `RANDOM`: the response that clients get most. Bodies of the same
  status can still vary with the `fake.*` helpers: a `json` root of
  `$if: fake.pick(1, 2) == 1`, with the two bodies as `then` and `else`,
  sends one or the other at random. `status` is never templated, so a
  503 cannot come at random. A connection Fault with a `probability`
  fails some requests, but the client sees a reset, a closed connection
  or the Stub's own response cut short, not a 503 and its `Retry-After`,
  so it tests other code.
- A global variable: the value after the request that sets it, such as
  the user who logs in.

A test that needs another answer, such as the 503 of a `RANDOM` route,
adds an Ephemeral Stub for its Session, and deletes it when the answer
should change back. The add call returns the Stub's ID:

```sh
ID=$(curl -s -H "Authorization: Bearer change-me" -H "baggage: smock-session=retry-1" \
  -d '{"request":{"method":"GET","path":"/api/v1/users/7"},"response":{"status":503,"headers":{"Retry-After":"5"}}}' \
  localhost:9090/v1/mocks/users-api/stubs | jq -r .stub.id)
curl -H "baggage: smock-session=retry-1" localhost:8080/api/v1/users/7   # 503
curl -X DELETE -H "Authorization: Bearer change-me" -H "baggage: smock-session=retry-1" \
  localhost:9090/v1/mocks/users-api/stubs/"$ID"
curl -H "baggage: smock-session=retry-1" localhost:8080/api/v1/users/7   # 200, from the file
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
| `GET /api/v1/orders/1` | 200, `{"id":1,"item":"book"}` | 404, unless a Stub for it is added. |
| `POST /api/v1/orders`, then `GET /api/v1/orders/3` | 201, then 200 with the new order | 404 and 404, unless the test adds Ephemeral Stubs. |
| `GET /api/v1/exports/7`, three times | 200, `{ "status": "running" }`, then `done`, then `running` again | 200, `{"status":"running"}`, then `done`, then `running` again |
| `POST /api/v1/password/reset`, three times | 202, `{ "message": "sent" }`, twice, then 429, `Retry-After: 60` and `{ "error": "too many requests" }` | 202, `{"message":"sent"}`, twice, then 429, `Retry-After: 60` and `{"error":"too many requests"}` |

Mockoon's JSON responses, and its `OPTIONS` answer, carry
`Content-Type: application/json; charset=utf-8`; smock's JSON responses
carry `application/json`, and its `OPTIONS` answer none.

## Behaviour that differs

Even a faithful translation answers some requests differently. These
differences were checked against Mockoon CLI 9.9.0 from 2026-10-17 to
2026-10-20, most of them by sending the same requests to both servers,
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
- **Dates.** Mockoon's date helpers take a format, and `{{now}}` without
  one gives `2026-10-17T14:01:59.615+00:00`. smock's `now()` always gives
  RFC 3339 in UTC with milliseconds, `2026-10-17T14:01:59.615Z`. For a
  full timestamp that changes only the notation, but a date changes
  shape: `{{now 'yyyy-MM-dd'}}`, `2026-10-17`, becomes
  `2026-10-17T14:01:59.615Z`, and a `dateTimeShift` with that format
  becomes a full timestamp too. A client that parses a date may refuse
  it; where clients need a date only, write a fixed one.
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
sample is JSON, `{method, path, query, headers, body}`, with the path and
the query values decoded and the cookies in `headers.Cookie`, and
`--seed` makes the fake data repeatable:

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

The last two pairs are differences from the section above: a form body,
which the example's Stubs do not read, and a trailing slash.

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

Each release of smock publishes binaries, an image and a Helm chart,
all under the release's version: its tag without the `v`. Take the
latest release, listed under
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
  CI's binary and the chart in a checkout. It had no Scenario Stubs then;
  those were checked later, with a local smock only.
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
| `SEQUENTIAL` | A Stub for each response, in order and without its rules, each requiring a state of the route's Scenario and moving it to the next, the last back to `Started` ([Answers that change between requests](#answers-that-change-between-requests)). |
| `RANDOM` | No counterpart: a Stub for the response to keep, and Ephemeral Stubs for the others ([Answers that change between requests](#answers-that-change-between-requests)). |
| Route `type: http` | Stubs, as above. |
| `type: crud` | Stubs for the reads, with one for each filtered, sorted or paged list that clients ask for; Ephemeral Stubs for a test's own changes. |
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
| Targets `global_var`, `data_bucket`, `templating` | No counterpart ([Answers that change between requests](#answers-that-change-between-requests)). |

### Responses

| Mockoon | smock |
|---|---|
| `statusCode` | `status`, from 200 to 599. |
| `label` | Part of the Stub's `id`, which is unique in the definition set. |
| `headers` | `headers`, a map from each name to a string, or to an array of strings for several `Set-Cookie` values. Names are compared case-insensitively. |
| `bodyType: INLINE` | `json` or `body`. |
| `body` | `json` for JSON, or `body` for text sent as written; with `template: true` when it uses helpers. |
| The default body, `{}` | `json: {}`. A Stub without a body sends an empty one. |
| `bodyType: FILE`, `filePath` | `bodyFile`, relative to `defs/files/`, with a Content-Type in `headers`. A templated `filePath` becomes one Stub per file. |
| `sendFileAsBody: false` | `Content-Disposition: attachment; filename="<file name>"` in `headers`, if clients need it. |
| `bodyType: DATABUCKET` | The bucket's value as `json`. |
| `databucketID`, `crudKey` | No counterpart; see `bodyType: DATABUCKET` and `type: crud`. |
| `disableTemplating` | No `template: true`. |
| `fallbackTo404` | A Stub with the path pattern after the Stubs of the files, with 404, the response's headers and its inline body ([Bodies, headers and templates](#bodies-headers-and-templates)). |
| `latency` | `fault: { delay: { fixed: <ms> } }`, with the environment's latency added. |
| `--enable-random-latency` | `fault: { delay: { uniform: { min: 0, max: <ms> } } }`. |
| `default` | The Stub with only the route's conditions, last among the route's Stubs. |
| `callbacks` | No counterpart. |
| `{{status 404}}` | No counterpart: `status` is never templated. |

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
| `{{now}}` | `${now()}`, in RFC 3339 only: a format is lost, and a date becomes a full timestamp ([Behaviour that differs](#behaviour-that-differs)). |
| `{{dateTimeShift days=1}}` | `${now(86400)}`, an offset in seconds. |
| `{{#repeat 3}}` | `{ $each: "range(1, 3)", as: i, do: … }`, in `json` only. |
| `{{#each}}` | `$each` over an array, or the values of a query parameter or a header, in `json` only. A literal `(array …)` is written out. |
| `{{#if}}`, `{{#switch}}` | `$if`, which compares with `==` or `!=` against a literal, in `json` only: one for each member that the block wraps, and `(eq (queryParam 'c') 'a')` becomes `query.c == 'a'`. |
| `{{setVar}}`, `{{getVar}}` | No counterpart: the expression, written wherever the variable is read. |
| `{{{x}}}` | `${raw(x)}`, in text templates. |
| `{{stringify x}}` | `${json(x)}` in text templates; in `json`, a string that is exactly `${x}`. |

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
| The admin API, under `/mockoon-admin` | The Admin API, on its own port, 9090 by default. |
| `PURGE /mockoon-admin/state` | `POST /v1/reset` with `{"scope":"all"}`, which clears the Ephemeral Stubs, the Journal and every Scenario state, so that sequences and request counts start over. |
| `PUT /mockoon-admin/environment` | Edit the files; smock reloads them. |
| The `mockoon/cli` image | `ghcr.io/hirunefu/smock:<version>`, from a release. |
| `import` | `smock import-openapi <document> --mock <name> --output <file>`, from the same OpenAPI document ([Importing OpenAPI](importing-openapi.md#notes-for-mockoon-users)). |
| `export` | No counterpart. |
