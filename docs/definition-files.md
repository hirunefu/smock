# Definition files

Definition files declare the Mocks smock serves and their Stubs. They live
in a definitions directory, such as `defs/`, that `smock serve --dir` and
`smock check` read:

- The Definition files are the regular files at the top level whose names
  end in `.json`, `.yaml` or `.yml`. Symlinks are followed. A YAML file
  means exactly what the equivalent JSON file means; smock accepts only the
  safe subset of YAML that the [README](../README.md) describes.
- Names that start with `.` are skipped, which covers the `..data` entries
  of Kubernetes ConfigMap volumes.
- smock reads the files in byte-wise order of their names, and reads them
  together, as one definition set: a Stub can belong to a Mock that another
  file declares.
- Body files live in the body-file subdirectory, `files/` by default
  (`--body-file-dir`, `SMOCK_BODY_FILE_DIR`). smock reads them when it
  loads the Definition files, and serves them from memory. Symlinks inside
  it are followed while they stay inside it; one that leads a file or a
  directory outside it is a problem, so that nothing outside is served.

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
  header.
- Hosts are exact names, with no wildcards. They are compared
  case-insensitively, without the port and without a trailing dot, so
  `Users.Example.com.:8080` is the Host `users.example.com`. An IPv6 address
  is written in brackets, such as `[::1]:8080`.
- A Host is written as a request's `Host` header carries it, so a port is
  digits, and nothing but a port follows a bracketed address. A Host that
  leaves no name once normalised, such as `.` or `:8080`, could never match
  and is rejected.
- Each Host belongs to at most one Mock. The same Host repeated within one
  Mock is fine.

A request whose Host no Mock lists, or that has none (HTTP/1.0 allows that),
goes to the Default Mock:

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

`host` is `null` for a request without a Host.

## How a Stub matches a request

A Stub's `request` lists the conditions a request must meet. Every condition
given must hold, and a condition that is left out matches anything, so a
Stub without `request` matches every request of its Mock.

| Condition | A request meets it when |
|---|---|
| `method` | its method is exactly this, case and all, such as `GET`. |
| `path` | its path, percent-decoded and without the query, is exactly this. `/users/a%20b` meets `"/users/a b"`. `{ "pattern": … }`: the pattern matches the whole path. |
| `query` | for each listed parameter, one of its values, decoded, is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent parameter fails. [`$not` and `$exists`](#negation-and-presence) are about the parameter as a whole instead, and may hold for an absent one. Parameters that are not listed are ignored. |
| `headers` | for each listed header, its name compared case-insensitively, one of its values is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent header fails. [`$not` and `$exists`](#negation-and-presence) are about the header as a whole instead, and may hold for an absent one. Headers that are not listed are ignored. |
| `cookies` | for each listed cookie, its name compared exactly, one of its values in the `Cookie` headers, as sent, is exactly the given value, or matches the given `{ "pattern": … }` as a whole, so an absent cookie fails. See [Cookies](#cookies). [`$not` and `$exists`](#negation-and-presence) are about the cookie as a whole instead, and may hold for an absent one. Cookies that are not listed are ignored. |
| `body` | a string: the body is exactly this text in UTF-8. `{ "pattern": … }`: the pattern matches the whole body. `{ "json": … }`: the body parses as JSON and contains the given value, which may hold patterns and [operators](#operators-in-json-conditions). `{ "form": … }`: the Content-Type says the body is a form, and each listed [field](#form-fields) meets its condition. `{ "xml": … }`: the body parses as XML, and the value at each [path](#xml-bodies) meets its condition. |

Query parameters are decoded as HTML forms encode them: `%20` and `+` both
stand for a space, so `?q=a+b` meets `"query": { "q": "a b" }`. A parameter
without `=` has the empty value. When a parameter or a header is repeated,
the condition holds when any one of its values matches. Each header field
line is one value: a client or proxy that joins repeated values into one
line, such as `X-Tag: b, a`, sends the value `b, a`, which `"X-Tag": "a"`
does not match; a pattern such as `{ "pattern": "(.*, )?a(, .*)?" }` does.

A `json` condition is a subset match:

- an object whose only member is `pattern`, with a string, is a pattern:
  see below;
- an object whose only key starts with `$` is an operator, such as
  `{ "$not": "admin" }`: see
  [Operators in json conditions](#operators-in-json-conditions);
- any other object needs each listed key, with a value that matches in
  turn, and may have other keys. A key written `$$name` is the key
  `$name`;
- an array needs the same length, matched element by element;
- any other value must be equal: strings exactly, numbers by their value
  (`1` and `1.0` are equal), and `true`, `false` and `null` themselves.
  Integers are compared exactly however many digits they have, so a 64-bit
  ID such as `9007199254740993` matches only itself; a number with a
  fraction or an exponent is compared as closely as a 64-bit float holds it.

A body that does not parse as JSON never meets a `json` condition.

A pattern in a `json` condition, such as
`"email": { "pattern": ".*@example\\.com" }`, holds when the value in its
place is a string that the pattern matches as a whole, or a number, `true`
or `false` whose JSON text it matches as a whole. So
`{ "pattern": "[0-9]{8}" }` meets both `20261017` and `"20261017"`. `null`,
objects and arrays never meet a pattern, and a missing key fails as it does
for any other value. Patterns follow the rules of
[pattern conditions](#pattern-conditions).

A number's text is its shortest form, as smock writes JSON: `1.50` is
matched as `1.5`, `1e3` as `1000` and `-0` as `0`. An integer keeps all its
digits, however many it has, and a number beyond a 64-bit float's range,
such as `1e400`, is matched as written. A string with a lone surrogate, such
as `"\ud800"`, has no UTF-8 form, so it never meets a pattern.

A pattern can also be the whole `json` value, as in
`{ "json": { "pattern": "[0-9]+" } }`. It is matched against the body
parsed as JSON, so it meets the bodies `42` and `"42"`. A pattern on the
body itself, `{ "pattern": "[0-9]+" }`, matches the body as text, so it
meets `42` but not `"42"`.

To match an object such as `{"pattern": "a.b"}` itself, nest a pattern in
it: `{ "pattern": { "pattern": "a\\.b" } }`. The outer `pattern` holds an
object, not a string, so it is literal JSON, and only the inner object is a
pattern. Unlike an exact value, the inner pattern also meets a number,
`true` or `false` whose text it matches, such as `1` for
`{ "pattern": "1" }`.

```json
{
  "id": "create-user",
  "mock": "users",
  "request": {
    "method": "POST",
    "path": "/users",
    "query": { "dryRun": "true" },
    "headers": { "Content-Type": "application/json" },
    "body": {
      "json": {
        "name": "Alice",
        "email": { "pattern": ".*@example\\.com" },
        "roles": ["admin"]
      }
    }
  },
  "response": { "status": 201 }
}
```

### Pattern conditions

The path, a query parameter, a header, a cookie, the body, a value inside
a `json` condition, a [form field](#form-fields) and the value at an
[XML path](#xml-bodies) can each be given as a pattern instead of an exact
value, in RE2 syntax:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": {
    "method": "GET",
    "path": { "pattern": "/users/[0-9]+" },
    "query": { "fields": { "pattern": "[a-z]+(,[a-z]+)*" } },
    "headers": { "Authorization": { "pattern": "Bearer [A-Za-z0-9._-]+" } }
  },
  "response": { "status": 200 }
}
```

- A pattern must match the whole value, not only part of it, so it needs
  no `^` or `$`: `/users/[0-9]+` meets `/users/42` but not
  `/users/42/orders` or `/api/users/42`.
- It is matched against the same value as an exact condition: the
  percent-decoded path without the query, the decoded values of a query
  parameter, the values of a header, and the body. When a parameter or a
  header is repeated, any one of its values may match. In a `json`
  condition, it is matched against the value in its place, as described
  above.
- The body is matched as text in UTF-8. `.` does not match a line break
  unless the pattern turns on the `s` flag, as in `(?s)BEGIN.*END`. A body
  that is not valid UTF-8 never meets a pattern, not even `(?s).*`.
- Exact, pattern and `json` conditions can be mixed on one Stub, which then
  matches only when all of them hold. Stubs with patterns are tried in the
  same order as any other Stub.

smock supports a subset of RE2 syntax, which the
[RE2 module's README](../re2/README.mbt.md#syntax-in-the-subset) lists:
literals, `.`, bracket classes, `\d`, `\w` and `\s`, anchors and word
boundaries, groups, alternation, repetitions (counts up to 1000) and the
flags `i`, `s` and `m`. Matching takes time linear in the length of the
value, whatever the pattern, so no pattern can stall smock.

Patterns are compiled once, when smock loads the Definition files. A
pattern that does not compile, or that uses RE2 syntax outside the subset,
such as the Unicode class `\p{Greek}`, makes the definition set invalid.
`smock check` reports it, and `smock serve` does not start, with the JSON
Pointer of the `pattern` field and the position of the problem in the
pattern, counted in characters from 0:

```console
users.json: /stubs/0/request/path/pattern: is not a valid pattern: position 7: missing closing )
users.json: /stubs/1/request/headers/X-Region/pattern: is not a valid pattern: position 0: Unicode class \p{Greek} is not supported in smock's RE2 subset
users.json: /stubs/2/request/body/json/email/pattern: is not a valid pattern: position 0: missing closing )
```

### Negation and presence

A query parameter's, a header's, a cookie's or a
[form field's](#form-fields) value, or the value at an
[XML path](#xml-bodies), can also be an operator: an object whose only key
starts with `$`.

- `{ "$not": <condition> }` holds exactly when the condition does not.
  `<condition>` is an exact value, a pattern or another operator.
- `{ "$exists": true }` holds when the parameter, header, cookie or form
  field is present, with any value, even an empty one.
  `{ "$exists": false }` holds when it is absent.

```yaml
request:
  headers:
    Authorization: { $not: { pattern: "Bearer .*" } }
    X-Debug: { $exists: false }
  query:
    status: { $not: draft }
```

This Stub answers a request without a Bearer token, without `X-Debug`, and
whose `status` is not `draft`.

An operator is about the name as a whole, not about one value:

- An exact value or a pattern holds when one of the values meets it, so it
  fails when the name is absent.
- `$not` holds when its condition does not. So `{ "$not": "draft" }` holds
  when no `status` is `draft`, including when there is no `status` at all.
  `?status=draft&status=x` does not meet it. A request without
  `Authorization` meets `{ "$not": { "pattern": "Bearer .*" } }`.
- Operators nest: `{ "$not": { "$not": "a" } }` is `"a"`, and
  `{ "$not": { "$exists": true } }` is `{ "$exists": false }`.

Names are always literal: `"query": { "$filter": "name eq 'a'" }` matches the
parameter `$filter`, as OData clients send it. Only a value can be an
operator.

Keys that start with `$` in a value are reserved for operators. An unknown
one, an operator beside another key, or an `$exists` that is not `true` or
`false` makes the definition set invalid, as `$includes` does here: it is
only allowed in a `json` condition. Each such key is reported, whatever the
order of the keys:

```console
users.json: /stubs/0/request/query/status/$nto: is not an operator: the operators here are "$not" and "$exists"
users.json: /stubs/1/request/headers/Authorization/pattern: is not allowed beside "$not": an operator is the only key of its object
users.json: /stubs/2/request/query/debug/$exists: must be true or false
```

### Operators in json conditions

In a `json` condition, any value can be an operator: the whole condition,
the value of a member, or an element of an array. An operator is about the
value in its place.

- `{ "$not": <condition> }` holds when the value does not meet the
  condition. A missing key meets `$not` of any condition that a missing
  key does not meet: `{ "$not": "x" }` holds when the key is missing, but
  `{ "$not": { "$exists": false } }` does not, since a missing key meets
  `$exists: false`.
- `{ "$exists": true }` holds when the key is present, whatever its value,
  even `null`. `{ "$exists": false }` holds when the key is missing. At the
  root, `{ "$exists": true }` holds for any JSON body.
- `{ "$includes": <condition> }` holds when the value is an array with at
  least one element that meets the condition, wherever it sits. It never
  holds for a value that is not an array.

`<condition>` is any `json` condition: a value, an object of keys, a
pattern or another operator.

```yaml
request:
  body:
    json:
      tags: { $includes: urgent }
      items: { $not: [] }
      coupon: { $exists: true }
      lines: { $includes: { sku: { pattern: "A-.*" } } }
```

This Stub answers a body whose `tags` array contains `"urgent"`, whose
`items` is not an empty array, that has a `coupon` key, even `null`, and
that has a line whose `sku` starts with `A-`.

- Operators nest. `{ "$not": { "$includes": "x" } }` holds when no element
  is `"x"`, and `{ "$includes": { "$not": "x" } }` when some element is not
  `"x"`.
- `null` still means JSON `null`: `"coupon": null` needs the key with the
  value `null`, and `"coupon": { "$exists": false }` needs it to be
  missing.
- `[]` still matches only an empty array. "Not empty" is
  `{ "$not": [] }`, which a missing key or a value that is not an array
  also meets. `{ "$includes": { "$exists": true } }` holds only for an
  array with at least one element.
- A body that does not parse as JSON never meets a `json` condition, so
  `{ "json": { "$not": … } }` fails on it too.

A key that starts with `$` is written `$$` and the rest, as in
[response templates](#structured-templates): `{ "$$ref": "#/a" }` matches
a body with the key `$ref`. A key that starts with one `$` and is not an
operator makes the definition set invalid, with a message that suggests
`$$`, and so do an operator beside another key and an `$exists` that is
not `true` or `false`:

```console
orders.json: /stubs/0/request/body/json/schema/$ref: is not an operator: the operators here are "$not", "$exists" and "$includes"; write "$$ref" for the literal key "$ref"
orders.json: /stubs/1/request/body/json/tags/length: is not allowed beside "$includes": an operator is the only key of its object
```

The format version is still 1, but two kinds of `json` condition written
for smock 0.1 now mean something else:

- an object whose only key is `$not`, `$exists` or `$includes` was literal
  JSON, and is now an operator;
- a key that starts with `$$`, such as `$$id`, matched that key as written,
  and now matches it with one `$` less, `$id`.

Any other key that starts with `$` in a `json` condition is now an error,
so a file with one fails to load rather than change its meaning: write
the key with `$$`.

### Cookies

`cookies` matches the cookies of the request by name:

```yaml
request:
  cookies:
    session: { pattern: "sess_.*" }
    debug: { $not: "1" }
```

This Stub answers a request whose `session` cookie starts with `sess_` and
that has no `debug` cookie with the value `1`.

smock reads cookies from the `Cookie` header like this:

- Every `Cookie` field of the request is read, so cookies that a client or
  a proxy splits over several lines still match.
- Each field is split on `;`, and each part is trimmed of spaces and tabs.
- The first `=` of a part separates the name from the value, so `a=b=c` is
  the cookie `a` with the value `b=c`. A part without `=` is skipped.
- Names are compared exactly, case and all: `Session` is not `session`.
- Values are compared exactly as sent. Quotes are part of a value, as
  RFC 6265bis says, so `token="abc"` meets `"token": "\"abc\""` but not
  `"token": "abc"`. Nothing is percent-decoded, so `name=a%20b` meets
  `"name": "a%20b"`, not `"name": "a b"`.

A cookie name can repeat, such as when a cookie is set for two paths. Then
the condition holds when any one of its values matches, as for a query
parameter, and `{ "$not": "1" }` holds only when none of them is `1`.
Names are literal, even when they start with `$`.

### Form fields

A `form` body condition matches the fields of an
`application/x-www-form-urlencoded` body, as HTML forms send it, by name:

```yaml
request:
  method: POST
  path: /login
  body:
    form:
      username: alice
      remember: { $not: "1" }
```

This Stub answers a login from `alice` that does not ask to be remembered,
such as `username=alice` or `remember=0&username=alice`, whatever the order
of the fields.

- Fields are decoded as query parameters are: `+` and `%20` both stand for
  a space, `%2B` is a `+`, and a field without `=` has the empty value. So
  `user+name=Alice%20Smith` meets `"user name": "Alice Smith"`.
- Names are compared exactly, case and all. They are literal, even when
  they start with `$`.
- The condition is any value condition: an exact value, a pattern, `$not`
  or `$exists`. When a field repeats, as in `tag=a&tag=b`, the condition
  holds when any one of its values matches, and `$not` holds when none
  does. An empty body has no fields.
- Fields that are not listed are ignored.

A form condition holds only when the request's Content-Type says that the
body is a form: its media type is `application/x-www-form-urlencoded`,
compared case-insensitively, with any parameters, such as
`; charset=UTF-8`. When a request has several Content-Type fields, the
first one counts. Any other Content-Type, or none, fails every listed
field, `$not` and `$exists: false` included, so a JSON or text body never
meets a form condition by accident. `{ "form": {} }` lists no field, so it
holds for any request whose Content-Type says the body is a form, as
`{ "json": {} }` holds for any body that is a JSON object.

The body is read as a form at most once per request, and only when smock
tries a Stub with a `form` condition. `multipart/form-data` bodies are not
read as forms: match them with a `pattern` on the body.

### XML bodies

An `xml` body condition maps paths into an XML body to value conditions.
It matches SOAP and other XML requests by meaning rather than by bytes:

```yaml
request:
  method: POST
  path: /soap
  body:
    xml:
      /Envelope/Body/GetUser/id: "42"
      /Envelope/Body/GetUser/@lang: { pattern: "en|ja" }
      /Envelope/Header/Trace: { $exists: false }
```

This Stub answers a request for user 42, in English or Japanese, without a
`Trace` header element, such as

```xml
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <u:GetUser xmlns:u="urn:users" lang="en">
      <u:id>42</u:id>
    </u:GetUser>
  </soap:Body>
</soap:Envelope>
```

A path is `/` followed by one or more element names separated by `/`,
optionally ending in `/@` and an attribute name:

- The first name is the root element's. Each further name selects the
  children with that name of the elements selected so far. A final
  `@name` selects that attribute of each of them.
- Names are local names. A prefix in the body is ignored, so a client that
  writes `S:Envelope` instead of `soap:Envelope` still matches, and a path
  names no prefix. Namespace URIs are not compared, so elements that
  differ only by namespace cannot be told apart.
- There are no wildcards, predicates, indexes, `//`, axes or functions.

What a node's value is:

- An element's value is all the text in it and in its descendants, in
  order, CDATA included, trimmed of whitespace at both ends. Comments are
  skipped. So `<id>42</id>`, `<id><![CDATA[42]]></id>`, and an `id`
  element with `42` indented on a line of its own all have the value
  `42`.
- An attribute's value is its text with each tab and line break turned
  into a space.
- References are decoded: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, and
  character references such as `&#38;`.
- Namespace declarations, `xmlns` and `xmlns:p`, are not attributes, so
  a path that ends in `@xmlns` makes the definition set invalid. An
  attribute with a prefix and the local name `xmlns`, such as `p:xmlns`,
  cannot be selected either.

The condition is any value condition: an exact value, a pattern, `$not` or
`$exists`. A path is a name whose values are the values of the nodes it
selects:

- When a path selects several nodes, such as repeated elements, the
  condition holds when any one of them meets it.
- When it selects none, only `$not` and `$exists: false` hold.
  `{ "$exists": true }` holds when it selects at least one, even an empty
  element.

The Content-Type is not consulted, as for `json`. `{ "xml": {} }` lists no
path, so it holds for any body that parses as XML. The body is parsed at
most once per request, and only when smock tries a Stub with an `xml`
condition. smock reads a restricted form of XML, so that no request can
read files or exhaust memory through it:

- The body is UTF-8, optionally with a byte order mark. An XML declaration
  that names another encoding fails.
- Any DOCTYPE fails, so no entity is ever declared or expanded. This rules
  out external entities (XXE) and entity expansion bombs. Only the five
  predefined entities and character references are decoded.
- Elements nest at most 256 deep.
- The body is no longer than `--body-limit` allows (10 MiB by default).
- It must be well-formed: one root element, matching tags, no repeated
  attribute, no `<` or bare `&` in text.

A body that breaks one of these rules fails every `xml` condition, even
one with no path, and `$not` and `$exists: false` included. It is not an error: the request gets
another Stub or the no-match response.

Paths are compiled once, when smock loads the Definition files. A path
that does not compile makes the definition set invalid, with the JSON
Pointer of the path and the position of the problem in it, counted in
characters from 0. A `/` in a path is written `~1` in a JSON Pointer:

```console
soap.json: /stubs/0/request/body/xml/~1Envelope~1~1id: is not a valid XML path: position 9: // (descendants) is not supported in smock's XML paths
soap.json: /stubs/1/request/body/xml/~1soap:Envelope: is not a valid XML path: position 1: prefix soap: is not supported in smock's XML paths; name the local name only
```

### Which Stub answers

The first Stub that matches answers. Within a Mock, Stubs are tried in this
order:

1. By `priority`: a lower number is tried first. A Stub without a priority
   is tried after every Stub with one.
2. Among equal priorities, in declaration order: files in byte-wise order
   of their names, then Stubs by their position in the file.

So a specific Stub can win over a general one wherever it is declared, by
giving it a lower priority number.

A request that carries a Session tries the Ephemeral Stubs its Session added
to the Mock through the Admin API before any of these, by their own
`priority`, the newest first among equal priorities; a request without a
Session, those added without one. Priority orders Stubs only within their
source: an Ephemeral Stub without a priority still comes before a Stub from
a Definition file with priority -2147483648.

smock does not try every Stub in turn: an index, built when the Definition
files are loaded, finds the Stubs whose `method` and exact `path` fit the
request. The index never changes which Stub answers. A Stub with a
`method` and no exact `path` is tried for every request with that method,
and a Stub with neither, such as one with only a path pattern, for every
request of its Mock, each in its place in the order. Large definition sets
stay fast when most Stubs have an exact path.

### Scenarios

A *Scenario* is a named state machine within a Mock. Its current state
decides which Stubs can match, and a Stub can move it to another state.
With Scenarios, the same request can get different answers at different
points of a flow: an order is pending until the client pays, and paid
after.

A Stub takes one `scenario` clause, next to `request` and `response`:

| Member | Meaning |
|---|---|
| `name` | The Scenario. Required. |
| `requires` | The Stub matches only while the Scenario is in this state. Without it, the Stub matches in every state. |
| `moveTo` | When the Stub is chosen, the Scenario moves to this state. |

A clause gives `requires`, `moveTo` or both; a clause with neither does
nothing, so it is an error. Scenario and state names are any non-empty
text, compared byte for byte, like Mock names and Stub IDs.

- Every Scenario starts in the state `Started`, with a capital S.
- A Scenario has no declaration. It exists because Stubs name it, and its
  states are `Started` and the ones its Stubs name. The Stubs of one
  Scenario may sit in different Definition files of the same Mock.
  `smock check` warns about a [required state that no Stub moves
  to](#a-state-that-no-stub-moves-to), so a typo in a state name is
  noticed.
- A Scenario belongs to its Mock. Two Mocks that use the same name each
  have their own Scenario, with its own state.
- `requires` is checked beside the request conditions. A Stub in another
  state is skipped, like a Stub that fails a condition, and the next one in
  the usual order is tried ([Which Stub answers](#which-stub-answers)).
  Scenario Stubs get no special priority.
- A Stub without a clause matches in every state, so adding a Scenario to a
  Mock does not disturb its other Stubs.
- A Stub with `moveTo` and no `requires`, such as a logout, moves the
  Scenario from any state. `moveTo: Started` sends it back to the start.
  Moving to the state it is already in changes nothing.

#### An example

The pending and paid answers are two Stubs with the same request and
different `requires`; the one whose state holds answers:

```yaml
mocks:
  - name: payments
    hosts: [payments.svc]
stubs:
  - id: order-pending
    mock: payments
    request: { method: GET, path: /orders/42 }
    scenario: { name: checkout, requires: Started }
    response: { status: 200, json: { status: pending } }
  - id: pay
    mock: payments
    request: { method: POST, path: /orders/42/pay }
    scenario: { name: checkout, requires: Started, moveTo: Paid }
    response: { status: 200 }
  - id: order-paid
    mock: payments
    request: { method: GET, path: /orders/42 }
    scenario: { name: checkout, requires: Paid }
    response: { status: 200, json: { status: paid } }
```

1. `GET /orders/42` answers `{"status":"pending"}`: `checkout` is in
   `Started`.
2. `POST /orders/42/pay` answers 200 and moves `checkout` to `Paid`.
3. `GET /orders/42` now answers `{"status":"paid"}`.
4. A second `POST /orders/42/pay` matches no Stub, since `pay` requires
   `Started`, and gets the Mock's 404.

A chain of states gives "the first answers, then another". This retry
flow resets the connection twice, then answers:

```yaml
stubs:
  - id: reset-1
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Started, moveTo: Reset once }
    response: { status: 200 }
    fault: { connection: { kind: reset } }
  - id: reset-2
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Reset once, moveTo: Reset twice }
    response: { status: 200 }
    fault: { connection: { kind: reset } }
  - id: ok
    mock: orders
    request: { method: GET, path: /orders/42 }
    scenario: { name: retry, requires: Reset twice }
    response: { status: 200, json: { id: 42 } }
```

#### When the state moves

The state moves the moment smock chooses the Stub, before it builds the
response. It moves whatever then happens to the response: a delay, a
connection Fault, a template error (a 500 that still counts as matched),
a client that disconnects, or a Journal that is off. So:

- Each request sees the moves of every request that reached smock before
  it. Two requests that race for the same step never both get it: the
  first moves the state, and the second sees the new one.
- A request on another connection sees the new state while a delayed or
  streamed response is still on its way.
- A retry flow moves on although its responses fail, as above.
- A request that matches no Stub, or that no Mock takes, moves nothing.
- The state that moves is the one of the Mock that answered. A request
  that falls through to the Default Mock moves the Default Mock's
  Scenario.
- A reload swaps the definitions between two requests, so a move never
  straddles two definition sets.
- `smock render` and the Admin render operation ignore the clause and move
  nothing.

#### Sessions and Ephemeral Stubs

State is kept per Mock, per [Session](../README.md#sessions-and-ephemeral-stubs)
and per Scenario. Concurrent tests that share a Mock each walk their own
flow, as long as each sends its own Session. Requests without a Session
share one state of their own, which is the simplest for a developer
running smock locally.

Each replica keeps its own state, as it keeps its own Ephemeral Stubs and
Journal. Tests that rely on Scenarios need one replica, or session
affinity. State is lost on restart.

Ephemeral Stubs take the same clause, including Scenarios and states that
no file names, so a test on a shared instance can build its own Scenario
without editing files. An Ephemeral Stub and a file Stub that name the
same Scenario of the same Mock share the Session's state, so an Ephemeral
Stub can replace one step of a Scenario from the files. Like the Stub, the
state belongs to the Session that added it: other Sessions never see it.
Deleting an Ephemeral Stub leaves the state as it is. A state that no Stub
names any more matches no `requires`, and the next reload that swaps in
new files sends it back to `Started` ([Reloading](#reloading)). A
[reset](../README.md#sessions-and-ephemeral-stubs) of the Session, of the
Mock or of everything clears the states in its scope, and sends their
Scenarios back to `Started`.

Through the Admin API, a test lists its Session's Scenarios of a Mock,
with the state each one is in, and sets the state of one, so that it can
start in the middle of a flow, or reset one Scenario by setting `Started`
([Sessions and Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs)).
It can set only a state that the files or its own Ephemeral Stubs name.

#### How state grows

smock stores one small entry for each Session, Mock and Scenario whose
state is not `Started`. A move back to `Started` deletes the entry, so
Sessions that never leave `Started`, or come back to it, cost nothing.
Nothing expires an entry.

A load test that gives every request a new Session, against Stubs that
move a state, therefore adds an entry with every request, and smock's
memory grows for the whole run. Give each virtual user one Session for
its whole run instead.

#### Seeing what moved

Each [Journal](../README.md#the-journal) entry records the move its Stub
made, as `scenario`:

```json
{ "name": "checkout", "from": "Started", "to": "Paid" }
```

A Stub with a clause but no `moveTo` records the state it answered in as
both `from` and `to`. An entry whose Stub has no clause, or that no Stub
answered, has `null`. When the Journal is off, for the Mock or for all,
the state still moves; only the record is missing.

A request that misses only because of the state gets a Near miss that
says so ([When no Stub matches](#when-no-stub-matches)). In the example
above, the second payment gets

```http
Smock-Near-Miss: pay; failed=scenario:checkout
```

and its Journal entry holds the condition with the state `pay` requires
and the state the Session's Scenario was in:

```json
{ "condition": "scenario:checkout", "expected": "Started", "actual": ["Paid"] }
```

Only a Stub with `requires` can fail this condition. Scenarios add no
other response header, so the system under test receives what it would
receive from the real service.

### When no Stub matches

The Mock answers with its `noMatch.status`, 404 by default, and the body
`{"error":"no Stub matched"}` with `Content-Type: application/json`. Give a
Mock the status its real service returns for unknown requests:

```json
{ "mocks": [{ "name": "users", "noMatch": { "status": 501 } }] }
```

The response also names the *Near miss*: the Stub that came closest, and
the conditions it failed, in a `Smock-Near-Miss` header. With this Stub:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": {
    "method": "GET",
    "path": "/users/1",
    "headers": { "X-Api-Key": "secret" }
  },
  "response": { "status": 200 }
}
```

`POST /users/1` without an `X-Api-Key` header gets

```http
Smock-Near-Miss: get-user; failed=method,header:x-api-key
```

The Near miss is the Stub of the Mock that failed the fewest conditions; on
a tie, the one tried first. The request's Ephemeral Stubs are candidates
too, in the order they are tried, and the header names them by their ID,
such as `eph-3`. Each of these counts as one condition: the method, the
path, each listed query parameter, each listed header, each listed cookie,
the body or each field of a [`form` condition](#form-fields) or each path
of an [`xml` condition](#xml-bodies), and the state a
[`scenario` clause](#scenarios) requires. They are named `method`,
`path`, `query:<name>`, `header:<name>` (in lower case), `cookie:<name>`,
`body`, `form:<name>` or `xml:<path>`, and `scenario:<name>`, in that
order. A parameter, a header, a cookie, a form field or an XML path counts
once whatever its condition, operators included. A `form` or `xml`
condition with no field or path counts as `body`, as `{ "json": {} }`
does. The header is ASCII only
and never carries what a condition expects or what the request sent: the
Stub ID, query, header, cookie, form field and Scenario names, and XML
paths are percent-encoded where they hold anything other than the
characters of an HTTP token, so `/order/@status` is sent as
`xml:%2Forder%2F%40status`. A Mock without Stubs, and a request for a Host
that no Mock answers, get no `Smock-Near-Miss` header.

A request that matches pays nothing for this: smock counts failed
conditions only once every Stub has failed to match.

The [Journal](../README.md#the-journal) records the full Near miss of each
unmatched request: every condition it failed, with what the Stub expects
and what the request sent. A test lists its Session's unmatched requests
with `GET /v1/journal/unmatched`
([README](../README.md#verifying-calls-and-unmatched-requests)).

What the Stub expects is the condition as the Stub writes it, operators
included. What the request sent is every value of the parameter, header,
cookie or form field, or of the nodes an XML path selects, in order, and
none when it is absent, or when the body is not a form or not XML. So a
request whose Content-Type is not a form's shows no value for any field of
a `form` condition. A request with `Authorization: Bearer abc` fails the
[negation example](#negation-and-presence) like this:

```json
{
  "condition": "header:authorization",
  "expected": { "$not": { "pattern": "Bearer .*" } },
  "actual": ["Bearer abc"]
}
```

What the request sent is shown as text. A body that is not valid UTF-8 is
shown with U+FFFD in place of each sequence that is not, so a failed exact
`body` condition can show an expected and an actual value that look the
same. The Journal entry itself keeps the body's bytes, in base64, up to
`--journal-body-limit`, and the Near miss in it cuts the body to the same
limit. It also keeps the values taken from a form or an XML body up to that
limit in total: each value counts its bytes and 32 more, the value that
reaches the limit is cut there, and the values after it are left out. So
even a body of many empty fields adds little to an entry.

`noMatch.headers` adds header fields to the response when no Stub
matches, such as CORS headers. Without them, a browser client that calls
the Mock from another origin gets a CORS error instead of the 404, and
cannot read the body or the Near miss. Before many cross-origin requests,
such as one with a JSON body, a browser also sends a preflight `OPTIONS`
request, and stops unless it gets a 2xx status. A Stub answers those:

```yaml
mocks:
  - name: users
    noMatch:
      status: 404
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Expose-Headers: Smock-Near-Miss, Smock-Mock
stubs:
  - id: preflight
    mock: users
    request:
      method: OPTIONS
      headers: { Access-Control-Request-Method: { pattern: ".+" } }
    response:
      status: 204
      headers:
        Access-Control-Allow-Origin: "*"
        Access-Control-Allow-Methods: GET, POST, PUT, DELETE
        Access-Control-Allow-Headers: Content-Type, Authorization
```

Preflight requests then match, so they are not among the unmatched
requests. A request with another method fails two of this Stub's
conditions, `method` and the header, so a Stub that fails only one is the
Near miss instead. With only a `method`, this Stub would be the Near miss
of most unmatched requests. Declare it after the Mock's other Stubs
([Which Stub answers](#which-stub-answers)), so that it also loses a tie.

`noMatch.headers` follows the rules of a Stub's `headers`
([Responses](#responses)), and cannot give `Content-Type` or
`Smock-Near-Miss` either, as smock sets them on this response. smock sends
the headers as written, never as templates, after `Content-Type` and
before `Smock-Near-Miss` and `Smock-Mock`. A request for a Host that no
Mock answers gets none of them.

### Turning the Journal off for a Mock

smock records every request a Mock answers in the Journal, unless the Mock
says `"journal": false`. A Mock that takes a high-rate load test can turn it
off, so that recording costs nothing:

```json
{ "mocks": [{ "name": "load-target", "hosts": ["api.example.com"], "journal": false }] }
```

A Journal query or verification whose filter names such a Mock is refused
with `journal_off`, rather than answered with no entries. Only such a
filter is refused: a filter that names no Mock is answered from the
requests that were recorded, which leave out this Mock's, and the
unmatched requests leave them out too. `--journal off` turns the Journal
off for every Mock, and then every query, verification and list of
unmatched requests is refused.

## Responses

A Stub's `response` has a `status`, `headers`, and a body.

`headers` maps each header name to a string or to an array of strings.
An array sends one field per value, in order, where the name stands.
This sends two `Set-Cookie` fields:

```json
"headers": { "Set-Cookie": ["session=abc; Path=/; HttpOnly", "theme=dark; Path=/"] }
```

An array is never empty. `Content-Type` takes one string. Names are
compared case-insensitively, so `Set-Cookie` and `set-cookie` cannot both
be given; give the name an array instead. In a YAML flow sequence a comma
ends a value. Write a value that has one, such as a cookie's `Expires`,
in block style or in quotes. smock sets `Content-Length` from the body;
`Content-Length`, `Transfer-Encoding` and `Connection` cannot be given,
nor can `Smock-Mock`, which smock adds when the Default Mock answers.

The body is either inline, as text in UTF-8:

```json
"response": { "status": 200, "body": "{\"id\":1}" }
```

or read from a body file, by its path relative to the body-file
subdirectory:

```json
"response": {
  "status": 200,
  "headers": { "Content-Type": "application/json" },
  "bodyFile": "users/1.json"
}
```

serves the bytes of `files/users/1.json` exactly as they are. The path
cannot leave the body-file subdirectory, and none of its names may start
with `.`. A path that breaks this rule, or names a file that does not
exist, is reported with the file and JSON Pointer of the `bodyFile`, by
`smock check` and when `smock serve` starts.

### Server-Sent Events

Instead of a body, a response can stream `events`, to mock a streaming API:

```json
"response": {
  "status": 200,
  "headers": { "Cache-Control": "no-cache" },
  "events": [
    { "data": "first" },
    { "delay": 250, "event": "update", "id": "2", "data": "line 1\nline 2" }
  ]
}
```

smock sends the status and the headers at once, always with
`Content-Type: text/event-stream`: a `Content-Type` the Stub gives is
replaced. Then, for each event, it waits the event's `delay` (in
milliseconds, counted from the previous event or, for the first one, from
the headers; 0 by default) and writes the event:

```text
data: first

event: update
id: 2
data: line 1
data: line 2

```

- `data` is required. Each of its lines becomes its own `data:` line.
- `event` (the event type) and `id` are written only when given. Each is
  one line, and `id` has no NUL characters.
- The stream ends after the last event. To an HTTP/1.1 client it is sent
  with chunked framing, so the connection carries the next request. An
  HTTP/1.0 client gets it unframed, and smock closes the connection to end
  it.
- A response with no body, to a `HEAD` request or with status 204 or 304,
  is the status and the headers alone. smock sends them at once and waits
  for no event.
- While a stream waits, smock serves every other connection. A client that
  closes the connection mid-stream ends that stream: smock notices when it
  next writes an event. Until then, which an event's long delay can put
  off, the stream keeps its connection, and a [drain](../README.md#run) on
  SIGTERM waits for it as for any stream in progress. smock does not watch
  the connection meanwhile, since a client may close its sending side once
  its request is sent and still read the stream.

### JSON bodies

A body can also be given as JSON, with `json`: any JSON value. smock sends
it as compact JSON in UTF-8, with `Content-Type: application/json` unless
`headers` gives a Content-Type:

```json
"response": { "status": 200, "json": { "id": 1, "price": 9.90 } }
```

sends `{"id":1,"price":9.9}`. smock writes every number itself, in the
shortest form that reads back as the same 64-bit float: `9.90` is sent as
`9.9` and `1e3` as `1000`, and an integer beyond 2^53 keeps its digits. When
the exact bytes matter, use `body`. A response gives at most one of `body`,
`bodyFile`, `json` and `events`, and an event gives exactly one of `data`
and `json`, which is sent as one `data:` line of compact JSON.

## Templates

With `template: true`, a response is rendered for each request: its body
and header values can take values from the request, loop over them, branch
on them and include fake data. Templates are parsed when the Definition
files are loaded, so a syntax error is reported by `smock check`, stops
`smock serve` at startup, and makes a reload keep the definitions it
serves, like any other problem; an Ephemeral Stub with one is refused with
400.

```yaml
- id: get-user
  mock: users
  request: { method: GET, path: { pattern: "/users/[0-9]+" } }
  response:
    status: 200
    template: true
    headers:
      X-Request-Id: ${header.x-request-id ?? 'none'}
    json:
      id: ${path[1]}
      lang: ${query.lang ?? 'en'}
      requestId: ${header.x-request-id ?? 'none'}
```

`GET /users/42?lang=ja` with `X-Request-Id: req-7` gets `X-Request-Id:
req-7`, `Content-Type: application/json` and
`{"id":"42","lang":"ja","requestId":"req-7"}`; without the query and the
header, `X-Request-Id: none` and `{"id":"42","lang":"en","requestId":"none"}`.

What is a template with `template: true`:

- `json` is a structured template, and so is the `json` of each event.
- `body`, a body file (`bodyFile`, which must then be UTF-8) and the
  `data`, `id` and `event` of each event are text templates.
- Header values are text templates, each value of an array on its own,
  except `Content-Type`, which must not contain `${`. An array's length is
  fixed: a template cannot add or drop a field.
- `status` and an event's `delay` are never templated.

With `template` off, nothing is parsed or rendered: `${` is plain text and
`$each` a plain key.

### Inserting values

`${ expr }` inserts a value, and `$${` writes a literal `${`; a `$` before
anything else is plain text. In YAML, a value can start with `${` in block
style without quotes (`id: ${path[1]}`); quote it in flow style
(`{ id: "${path[1]}" }`) and when the expression contains `: ` or ` #`. In
JSON, `${…}` sits in an ordinary string; string literals in an expression
may use single quotes (`"${query.lang ?? 'en'}"`).

An expression is a value, a request field, a literal (`'text'` or `"text"`
with the escapes `\'`, `\"` and `\\`, a JSON number, `true`, `false` or
`null`) or a helper call, optionally followed by fallbacks: `a ?? b` is `a`
when `a` is present, otherwise `b`. There is no arithmetic, no string
operator and no user-defined function. The words `for`, `if`, `else`,
`end`, `each` and `params` are reserved.

| Name | Value |
|---|---|
| `method` | The request method, such as `GET`. |
| `path` | The percent-decoded path without the query, as conditions compare it. |
| `path[n]` | Segment `n` of that path, counted from 0 after the leading `/`: for `/users/42`, `path[0]` is `users` and `path[1]` is `42`. |
| `query.NAME` | The first decoded value of the query parameter. |
| `header.NAME` | The first value of the header, its name compared case-insensitively; each field line is one value. |
| `body` | The body parsed as JSON. `body.a.b`, `body.items[0]` and `body['odd.key']` walk into it. |
| `bodyText` | The body as text; bytes that are not UTF-8 become U+FFFD. |
| `loop.index` | The position in the innermost `$each`, from 0. |
| a loop variable | The current element of the `$each` that names it with `as`. |

A name in a reference is ASCII letters, digits, `_` and `-`; write any other
name as `['…']`, such as `query['page size']`.

### Structured templates

In `json`:

- A string that is exactly one `${expr}` gives the value with its own type:
  a number stays a number and an object stays an object. Any other string
  gives a string, each value written as text.
- `{ "$each": expr, "as": name, "do": template }` gives an array, one
  element per item. It walks an array (from `body` or a loop variable),
  every value of a query parameter or a header (none when it is absent), or
  `range(a, b)`.
- `{ "$if": cond, "then": template, "else": template }` gives `then` or
  `else`. Without `else`, a false condition leaves the member or the array
  element out; at the root of `json`, `else` is required. A condition is
  an expression, optionally negated with `!` and compared with a literal
  with `==` or `!=`. It is true when the value is present and neither
  `null` nor `false`; strings compare exactly and numbers by value, and a
  string never equals a number.
- An object with `$each` or `$if` has only the keys listed for it. Other
  keys that start with `$` are reserved: write `$$name` for the key
  `$name`. Keys are never templated.
- The output is compact JSON in UTF-8, members in the order written, with
  numbers written as for a [JSON body](#json-bodies).

```yaml
json:
  orderId: ${fake.uuid()}
  customer: ${body.customer.name}
  lines:
    $each: body.items
    as: item
    do:
      sku: ${item.sku}
      qty: ${item.qty}
      status:
        $if: item.qty == 0
        then: backordered
        else: reserved
```

Text templates have no loops and no conditionals.

### Helpers

| Helper | Arguments | Output |
|---|---|---|
| `fake.uuid()` | none | A version 4 UUID in lower case. |
| `fake.int(min, max)` | integer literals from -(2^53 - 1) to 2^53 - 1 | An integer from `min` to `max`, both included, each equally likely. |
| `fake.decimal(min, max, places)` | integer literals from -10^9 to 10^9; `places` from 1 to 6 | A number from `min` to `max` in steps of 10^-places, written with exactly `places` decimals, such as `104.30`. |
| `fake.bool()` | none | `true` or `false`. |
| `fake.pick(v1, …, vn)` | 1 to 100 literals | One of them, with its type. |
| `fake.hex(n)` | `n` from 1 to 64 | `n` lower-case hex digits. |
| `fake.word()`, `fake.words(n)` | `n` from 1 to 100 | One word, or `n` words separated by spaces, from a built-in list of 256 lower-case English words. |
| `fake.firstName()`, `fake.lastName()`, `fake.name()` | none | A first name, a last name, or both, from built-in lists of 128 ASCII names each. |
| `fake.email()` | none | `<first>.<last><nn>@example.com` in lower case. |
| `now()`, `now(s)` | `s`: an integer literal, seconds, may be negative | The time of the request plus `s` seconds, RFC 3339 in UTC with milliseconds. |
| `nowMillis()`, `nowMillis(s)` | as for `now` | The same instant in milliseconds since the Unix epoch. |
| `number(x)` | a string or a number | `x` as a number. |
| `range(a, b)` | integer literals or `number(…)` | The integers from `a` to `b`, for `$each`; none when `a > b`. |
| `json(x)` | any value | Text templates only: `x` written as JSON. |
| `raw(x)` | a string, number, boolean or null | Text templates only: `x` without escaping. |

The word and name lists are part of format version 1. A matched request
takes exactly one 64-bit output from its Stub's random source (its own
generator with `fault.seed`, otherwise the process generator, see
[Seeds](#seeds)), whatever its template draws: the Fault decisions draw
from a generator seeded with it, and the helpers from another one seeded
with it XOR a fixed constant, in render order (header values in the order
written, an array's values in order, then the body, members and loop
iterations in order, or the events in order, each event's `event`, `id`,
then `data` or `json`). So a seeded Stub repeats its helper output on
every run, on native and on wasm-gc alike, and adding fake data never
changes its Faults.

`now()` and `nowMillis()` read the time smock received the request at,
never the clock while rendering; in an event, they add the delays of the
events up to and including it:

```yaml
response:
  status: 200
  template: true
  headers: { Cache-Control: no-cache }
  events:
    - { event: price, id: "1", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, event: price, id: "2", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, event: done, data: "[DONE]" }
fault: { seed: 7 }
```

### Escaping and line breaks

- In `json`, smock writes the JSON itself, so every string is escaped.
- In `body` and a body file, inserted values are escaped by the media type
  of the response's `Content-Type`, compared case-insensitively and
  without its parameters: for `application/json` and `*/*+json`, as the
  content of a JSON string (write `json(x)` for a value outside a string,
  which is not escaped again); for `text/html`, `text/xml`,
  `application/xml` and `*/*+xml`, `&`, `<`, `>`, `"` and `'` become
  character references (also in the output of `json(x)`); for any other
  type, or none, not at all. `raw(x)` is never escaped. A `text/html` body
  file with `<p>Hello, ${query.name ?? 'guest'}</p>` answers
  `?name=<b>Ann</b>` with `<p>Hello, &lt;b&gt;Ann&lt;/b&gt;</p>`.
- In text, a string is written as it is, a number as in `json`, and `true`,
  `false` and `null` as those words; an object or an array needs `json(x)`.
- In a header value, every control character except tab, CR and LF
  included, becomes a space after rendering, so a value never adds a line
  to the response head. In an event's `id` and `event`, every control
  character becomes a space. An event's `data` is written as rendered, so
  a value with line breaks gives several `data:` lines.

### Missing values and render errors

A reference is missing when it names nothing: an absent query parameter or
header, a path segment past the end, a body path that leads nowhere, or
`body` when the body is not JSON. A missing value in `${…}` or in `$each` is
an error unless `??` gives a fallback (`${query.lang ?? 'en'}`,
`${body.note ?? null}`); a loop over an absent query parameter or header
runs zero times, and in `$if` a missing value is never an error: it is
false, and it equals no literal (so `query.x != 'a'` holds when `x` is
absent). A call with a missing argument is missing too.

Type errors are errors as well: a loop over what is not an array,
`number(x)` of text that is not a JSON number, an object or an array in
text, and a bound exceeded. `range` gives at most 1000 values, one response
runs at most 10,000 loop iterations in all, and a rendered body, or all the
events of a response together, takes at most 1 MiB. Bounds that literals
give are checked when the files are loaded.

When a template cannot be rendered for a request, the client gets status
500, `Content-Type: application/json` and
`{"error":"template failed","stub":"<id>","at":"<JSON Pointer within the Stub>","message":"<what>"}`,
such as `"at":"/response/json/customer","message":"body.customer.name is missing"`.
A delay Fault still applies first, and a connection Fault still replaces
the response. A stream is rendered whole before its head is sent, so a
failed event also gives this 500 and no stream. The Journal entry records
the 500 and `templateError`, and no log line is written.

### Errors when loading

A template problem found when the files are loaded is reported with the
file and the JSON Pointer of the field (for a body file, of `bodyFile`), and
a message that starts with `template:` and gives the column of the problem
in a one-line string, or its line and column in a text of several lines:

```text
users.yaml: /stubs/0/response/json/id: template: column 3: unknown helper "fake.phone": not one of the helpers smock has
users.yaml: /stubs/1/response/bodyFile: template: line 3, column 5: unknown helper "fake.nickname": not one of the helpers smock has
```

Every name, loop variable and helper, the number and the literal arguments
of each call, the keys of `$each` and `$if` objects, reserved keys, `${` in
a key or in `Content-Type`, `json()` and `raw()` in `json`, and a templated
body file that is not UTF-8 are checked then.

### Rendering a template

`smock render` and the Admin render operation render a Stub for a sample
request, templates included, and show the time and the seed they used. A
sample's cookies come from its `headers.Cookie`, and its form fields from
its body when its `headers.Content-Type` says the body is a form.
`--time` (the Admin API's `time`) is the time of the request; `--seed`
(`seed`) gives the output the request takes from its Stub's source as the
first output of a generator seeded with it, so a rendering with seed `S`
shows what the first matched request of a Stub with `fault.seed: S` gets.
Without a seed they use the Stub's `fault.seed`, or a fresh seed when it
has none. With the same time and seed, a rendering is the same on every
run. A template that fails for the sample shows the 500 and the error.

## Faults

A Stub can inject Faults, to test how a client handles slow and failing
calls. Its `fault` has a delay, a connection Fault, or both, and an optional
seed:

```json
{
  "id": "get-user",
  "mock": "users",
  "request": { "method": "GET", "path": "/users/1" },
  "response": { "status": 200, "body": "{\"id\":1}" },
  "fault": {
    "delay": { "lognormal": { "median": 80, "sigma": 0.6 }, "probability": 0.5 },
    "connection": { "kind": "close", "probability": 0.01 },
    "seed": 42
  }
}
```

### Delays

A `delay` makes smock wait before it writes the status line. Meanwhile it
keeps serving other connections. The delay is drawn from one distribution,
in whole milliseconds:

| Distribution | Delay |
|---|---|
| `"fixed": 100` | always 100 ms. |
| `"uniform": { "min": 50, "max": 150 }` | a whole number of milliseconds from `min` to `max`, both included, each equally likely. `min` must not exceed `max`. |
| `"lognormal": { "median": 80, "sigma": 0.6 }` | log-normal: half the delays are below `median`, and `sigma`, the standard deviation of the delay's natural logarithm, sets how long the tail of slow responses is. |

`probability`, from 0 to 1, is the share of matched requests that are
delayed. Without it, every matched request is.

### Connection Faults

A `connection` Fault makes a request fail at the connection level, instead
of getting its response:

- `reset`: smock reads the whole request, body included, then resets the
  connection (an RST) without writing anything. The client gets a
  connection-reset error, not an empty response. On the TLS port, smock
  sends no `close_notify` first. Should the operating system refuse the
  reset, smock logs an error (`cannot reset the connection`) and closes the
  connection with a FIN instead.
- `close`: smock reads the request, then closes the connection (a FIN)
  without writing anything.
- `partial`: smock writes the status line, the headers, with the
  `Content-Length` of the whole body, and the first half of the body, then
  closes the connection. The client sees a response cut short. For
  Server-Sent Events, the first half is the first half of the events,
  rounded down, each after its delay, and the stream is not ended.
  - A response with no body bytes to halve, such as an empty body or a
    response to `HEAD`, would be whole that way. smock leaves out the empty
    line that ends its headers instead, so the client still sees it cut
    short.
  - A stream of Server-Sent Events to an HTTP/1.0 client ends when the
    connection closes, so a client cannot tell a partial one from a whole
    stream with fewer events.

`probability`, from 0 to 1, is the share of matched requests that fail;
without it, every matched request fails. A Stub with both a delay and a
connection Fault waits first, then fails.

A request that asks for `100 Continue` (`Expect: 100-continue`) gets it
before its body is read, as HTTP/1.1 requires of a client that waits for
it, and so before smock knows which Stub, and which Fault, applies. Its
`reset` or `close` then comes after that interim response, which is all
the client receives. smock sends `100 Continue` also when the body arrives
without waiting for it.

### Seeds

Each matched request draws whether its delay and its connection Fault
apply, and how long the delay is.

- A Stub with a `seed`, from 0 to 9007199254740991, has its own generator.
  smock creates it when it loads the Definition files, and again from the
  seed when a [reload](#reloading) swaps in a new definition set, and it
  advances once per request the Stub matches. An Ephemeral Stub with a seed
  gets its own generator when it is added, which a reload keeps. So the n-th
  request a seeded Stub matches gets the same Faults in every run, whatever
  requests other Stubs get. The generator is a fixed algorithm, the same on
  every platform.
- Stubs without a seed draw from the process generator, which they share.
  smock picks its seed at startup and logs it:

  ```json
  {"time":"2026-10-13T09:12:44.512Z","level":"info","msg":"random seed","seed":5126750341862113}
  ```

  To replay a run, start smock with that seed (`--seed`, `SMOCK_SEED`): the
  same requests in the same order then get the same Faults.

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

`smock serve` watches the definitions directory, body-file subdirectory
included, and reloads the definition set when its files change, without a
restart:

- Adding, editing, renaming or removing a Definition file or a body file
  triggers a reload. So does a Kubernetes ConfigMap update, which swaps the
  `..data` symlink and keeps the visible names. Any change in the directory
  counts, so a reload can also find nothing new.
- When `--dir` goes through a symlink that is pointed at a new directory,
  as git-sync does for each commit (`--dir /git/current/mocks`), smock goes
  on watching the directory it found at first until that one changes or is
  removed. git-sync removes the directory it replaced at once by default,
  so the new commit is reloaded right away and watched from then on. When
  the old directory stays, as with git-sync's `--stale-worktree-timeout`,
  the new commit is found by the next poll, within 10 s.
- Changes are coalesced: smock reloads once they have been quiet for
  250 ms, so a burst of changes gives one reload. It also polls the
  directory every 10 s, in case a change went unnoticed, and reloads when
  the files differ from those it read last. A definitions directory that
  does not exist yet is polled until it appears. One that cannot be watched
  for another reason, such as the inotify limits, is only polled, and smock
  logs a warning.
- A poll first compares the names in the directories, where each file
  really is once symlinks are resolved, and the modification and change
  times of the files with those of the last check, and reads the files only
  when something differs. That takes a few calls for each file instead of
  reading it, which saves most of a poll's CPU when the files are a few
  large ones, as in the benchmark's set, and little when they are many
  small body files; startup and each check that reads pay for both. After a
  read that met a problem reading the directory, such as a file that cannot
  be read, each poll reads again while the problem lasts. A file time ahead
  of the clock is logged as a warning, once. A modification time ahead, as
  from an archive made on a host whose clock ran ahead, changes nothing
  else; a change time ahead, which only a clock set back gives, makes each
  poll read the files until the clock passes it.
- A reload reads and validates every file, builds a whole new definition
  set and swaps it in at once, so no request sees half of a change.
  Requests already being handled finish with the set they started with,
  body-file bytes included.
- Ephemeral Stubs survive the swap. A Mock the new set no longer declares
  is gone: its Ephemeral Stubs are dropped, and its Hosts resolve like any
  unknown Host.
- [Scenario](#scenarios) state survives the swap while its name still
  exists. A Scenario's state, for a Session or for requests without one,
  stays when a Stub of the same Mock still names it for that Scenario, in
  `requires` or in `moveTo`: a Stub in the files, or one of that Session's
  own Ephemeral Stubs. Any other state goes back to `Started`. The states
  of a Mock that is gone are dropped with it. So editing a response body
  leaves tests in progress where they are in their flows, and a state that
  only a test's own Ephemeral Stubs name survives a change to the files.
- Renaming a state loses the state of tests in progress. A test whose
  Scenario is in the old state goes back to `Started` in the middle of its
  flow, and its next requests may miss. Rename a state when no test relies
  on it.
- When the new set is invalid, smock keeps serving the current one and
  reports every problem, as `smock check` would, in the Admin API status, in
  a log entry and in the reload metric. Scenario state stays as it is. Fix
  the files, and the next reload swaps the fixed set in.
- When the new set has the digest of the one served, nothing is swapped,
  and Scenario state stays as it is.
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
`oldDigest`, `newDigest` and `scenarioStatesReset`, or `definitions reload
failed` with the digest still served and every error.
`scenarioStatesReset` is the number of Scenario states the reload sent
back to `Started`, 0 when there are none. The states dropped with a
removed Mock are not counted. Like every log field, these are a diagnostic
aid, and a release may change them. The Prometheus counter
`smock_definition_reloads_total` counts reloads by `result`. A failed reload
does not change readiness: `/readyz` on the admin port still passes, so one
bad commit does not drain every Pod.

## Checking a definitions directory

`smock check <dir>` reads a definitions directory the way `smock serve`
does, so a directory that passes `smock check` loads in `smock serve`, and
the reverse. It prints every problem on its own line, with the file and a
JSON Pointer to the value, and exits with status 1. A valid directory
prints nothing, apart from [warnings](#warnings), and exits with status 0.
A directory that does not exist is an empty definition set, as for
`smock serve`, so it passes too; `smock check` then says on stderr that the
directory does not exist, so that a mistyped path is noticed.

```console
$ smock check defs
20-orders.json: /stubs/0/mock: no file declares the Mock "orders"
20-orders.json: /stubs/1/request/path: must start with /
$ echo $?
1
```

`smock check` also checks the rules the Schema cannot express, because they
span the Mocks and files of the set: Mock names and Stub IDs are unique, no
two Mocks claim the same Host after normalisation, at most one Mock is
marked `default`, and every Stub names a Mock that some file declares. A
duplicate is reported where it occurs the second time, in file-name order,
and the message names the first. It also compiles every
[pattern](#pattern-conditions), which the Schema accepts as any string, and
rejects two names in one response's `headers` that differ only in case,
since the Schema compares names exactly. It rejects a key repeated within one
JSON object, as YAML files reject it: JSON parsers disagree on which of the
two values counts, and the Schema sees only one of them. It checks the
[operators in a `json` condition](#operators-in-json-conditions), where the
Schema accepts any JSON.

In CI, run it as a step that fails the build:

```yaml
- run: smock check defs
```

### Warnings

For a valid directory, `smock check` also warns about two things that do
not stop the directory from loading: a Stub that can never match, and a
Stub that requires a state that no Stub moves to. Each warning is one
line, marked `warning:`, with the file and a JSON Pointer. Warnings do not
change the exit status:

```console
$ smock check defs
users.json: /stubs/1: warning: the Stub "user-1" can never match: the Stub "any-user" at users.json: /stubs/0 is tried first and matches every request this one would
payments.yaml: /stubs/2/scenario/requires: warning: the Stub "order-paid" requires the state "Payed" of the Scenario "checkout", but no Stub in the Definition files moves "checkout" to "Payed"; only the Admin API or an Ephemeral Stub can
$ echo $?
0
```

#### A Stub that can never match

A Stub can never match when an earlier Stub of the same Mock always
matches first. The warning points at that Stub and names the earlier one.

"Earlier" means earlier in the order Stubs are [tried](#which-stub-answers).
A Stub `s` is shadowed by an earlier Stub `t` when `t` has a subset of
`s`'s conditions:

- `t` has no method, or the same method as `s`;
- `t` has no path, the same exact path as `s`, or a pattern that matches
  `s`'s exact path;
- each of `t`'s query, header, cookie and body conditions is also in `s`,
  written the same way (header names in any case), operators included;
  each field of `t`'s `form` condition and each path of its `xml`
  condition is in `s`'s, in any order, with the same condition;
- `t` has no `requires`, or `s` names the same [Scenario](#scenarios) with
  the same `requires`. `moveTo` plays no part, since it does not change
  whether a Stub matches.

So the pending and paid Stubs of the [Scenario example](#an-example) do not
shadow each other: they have the same request, but require different
states. Two Stubs with the same request that require the same state are
still reported.

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
so CI checks it with the rest. CUE (`cue export --out json`) and Pkl
(`pkl eval -f json`) work the same way.
