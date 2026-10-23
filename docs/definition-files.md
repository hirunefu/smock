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
  (`--body-file-dir`, `SMOCK_BODY_FILE_DIR`), and so do the JSON files of
  [Data buckets](#data-buckets). smock reads them when it loads the
  Definition files, and serves them from memory. Symlinks inside
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
- `{ "$last": <condition> }` holds when the value is an array with at least
  one element, and its last element meets the condition. It never holds
  for an empty array or a value that is not an array.

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

`$last` matches the last message of a conversation, however long it is.
An LLM client sends the whole conversation in each request, so a Stub can
answer the turn after a tool call. Each API has its own form:

```yaml
stubs:
  # OpenAI Chat Completions: the last message is a tool result.
  - id: chat-after-tool
    mock: llm
    request:
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: tool } } } }
    response: { status: 200 }
  # Anthropic Messages: the last message is a user message that holds a
  # tool result.
  - id: messages-after-tool
    mock: llm
    request:
      path: /v1/messages
      body:
        json:
          messages:
            $last: { role: user, content: { $includes: { type: tool_result } } }
    response: { status: 200 }
  # OpenAI Responses: the last input item is a tool result.
  - id: responses-after-tool
    mock: llm
    request:
      path: /v1/responses
      body: { json: { input: { $last: { type: function_call_output } } } }
    response: { status: 200 }
```

The Responses API also takes `input` as a string. A string is not an
array, so it never meets `$last`.

`$last` nests as the other operators do.
`{ "$not": { "$last": { "role": "tool" } } }` holds when the last message
is not a tool result, and also for an empty array, a value that is not an
array and a missing key. `{ "$last": { "role": { "$not": "user" } } }`
holds when the last element is an object whose `role` is missing or is
not `user`.

A key that starts with `$` is written `$$` and the rest, as in
[response templates](#structured-templates): `{ "$$ref": "#/a" }` matches
a body with the key `$ref`. A key that starts with one `$` and is not an
operator makes the definition set invalid, with a message that suggests
`$$`, and so do an operator beside another key and an `$exists` that is
not `true` or `false`:

```console
orders.json: /stubs/0/request/body/json/schema/$ref: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$ref" for the literal key "$ref"
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
the key with `$$`. This is why `$last`, added later, changed no file: a
file with a lone `$last` key failed to load before, and `$$last` still
means the key `$last`.

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

Templates read cookies the same way, with
[`cookie.NAME`](#inserting-values).

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
request of its Mock, each in its place in the order. So is a [CRUD
Stub](#crud-stubs), behind a quick test of its path's prefix. Large
definition sets stay fast when most Stubs have an exact path.

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

Each replica keeps its own state, as it keeps its own Ephemeral Stubs,
Variables, copies of Data buckets and Journal. Tests that rely on Scenarios need one replica, or
session affinity. State is lost on restart.

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
does. A [CRUD Stub](#crud-stubs) counts two, `method` and `path`
([A CRUD Stub's Near miss](#a-crud-stubs-near-miss)). The header is
ASCII only and never carries what a condition expects or what the request
sent: the Stub ID, query, header, cookie, form field and Scenario names,
and XML paths are percent-encoded where they hold anything other than the
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
before `Smock-Near-Miss` and `Smock-Mock`. A `Date` given here replaces
the one smock sends, as a Stub's does. A request for a Host that no
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

A Stub's `response` has a `status`, `headers`, and a body. A Stub can give
several responses to pick from instead
([Several responses](#several-responses)).

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

smock sends a `Date` header with the current time on every final
response, such as `Date: Thu, 22 Oct 2026 14:37:10 GMT`, and none on an
interim `100 Continue`. A Stub may give its own `Date`,
in any case, such as a fixed one for testing a client's caching. smock
then sends that one as written and adds none.

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

### Range requests

A body file serves byte ranges, so that clients that resume downloads or
stream media can be tested against smock. Nothing in the Definition file
turns this on. A response serves ranges when:

- its status is 200;
- its body is a body file, and `template` is off;
- its headers give neither `Content-Range` nor `Accept-Ranges`.

```yaml
- id: get-video
  mock: media
  request: { method: GET, path: /video.mp4 }
  response:
    status: 200
    headers: { Content-Type: video/mp4 }
    bodyFile: video.mp4
```

For a `video.mp4` of 1000 bytes:

- `Range: bytes=0-99` gets 206 Partial Content, with
  `Content-Range: bytes 0-99/1000`, `Accept-Ranges: bytes` and the first
  100 bytes.
- `Range: bytes=1000-` gets 416 Range Not Satisfiable, with
  `Content-Range: bytes */1000` and no body.
- A request without `Range` gets the whole file with 200 and
  `Accept-Ranges: bytes`.

smock serves a single byte range, and reads the `Range` field by the
grammar of RFC 9110:

- `first-last`, `first-` and `-suffix` (the last `suffix` bytes) are
  taken. The unit `bytes` is compared case-insensitively.
- A last position at or past the end means the end. A suffix longer than
  the file selects the whole file, with 206.
- A first position at or past the end, or a suffix of 0, cannot be
  satisfied: 416, with `Content-Range: bytes */<length>` and no body.
- A number too large to hold is past the end. As a first position, the
  range cannot be satisfied; as a last position, it means the end; as a
  suffix, it selects the whole file.
- The Stub's headers stay on the 206 and the 416, and smock adds its
  fields after them. The 416 carries no `Accept-Ranges`.

These get the whole body with 200 and `Accept-Ranges: bytes`, as RFC 9110
lets a server ignore `Range`:

- several ranges, such as `bytes=0-99,200-299`;
- more than one `Range` field;
- a malformed field, such as `bytes=100-99`, whose last position is below
  its first;
- another unit, such as `items=0-9`;
- any `If-Range`. smock has no validators, such as `ETag`, so RFC 9110
  says to ignore `Range` then;
- an empty body file.

Only a GET is served a range, since RFC 9110 defines range handling for
GET only. A `HEAD` ignores `Range`, and its 200 still carries
`Accept-Ranges: bytes`. A Stub with `method: GET` still does not answer
`HEAD`. Other methods get the response as written, without
`Accept-Ranges`.

Some Stubs are left alone, so that partial responses written by hand keep
working:

- a Stub that gives status 206, or a `Content-Range` header of its own;
- a Stub that gives `Accept-Ranges` itself, such as `Accept-Ranges: none`.
  It serves no ranges, and keeps its own value.

With [`responses`](#several-responses), the response picked decides.
[Ephemeral Stubs](../README.md#sessions-and-ephemeral-stubs) have no body
files, so they never serve ranges.

A [delay](#delays) applies to a 206 or a 416 as to any response. A
`partial` [connection Fault](#connection-faults) sends the head of the
206, with its `Content-Length`, and the first half of the range. The
[Journal](../README.md#the-journal) records the status sent: 206 or 416.
`smock render` and the Admin render operation apply the same rule to the
sample's `Range` header ([Rendering a template](#rendering-a-template)).

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
`bodyFile`, `json`, `events` and [`llm`](#llm-responses), and an event
gives exactly one of `data` and `json`, which is sent as one `data:` line
of compact JSON.

### Several responses

A Stub can give `responses`, a list of responses with weights, instead of
`response`. Each matched request gets one of them, picked at random. This
Stub answers about one request in ten with a 503:

```yaml
- id: get-prices
  mock: market
  request: { method: GET, path: /prices }
  responses:
    - { weight: 9, status: 200, json: { price: 101 } }
    - { weight: 1, status: 503, headers: { Retry-After: "5" }, json: { error: unavailable } }
  fault: { seed: 7 }
```

- A Stub gives exactly one of `response` and `responses`.
- `responses` holds 1 to 100 responses, in the order written. Each is a
  response as `response` gives it, with its own status, headers, body,
  body file, `json`, events or `llm`, and `template`, plus `weight`.
- `weight` is an integer from 1 to 1,000,000, by default 1. A response is
  picked with the probability of its weight over the sum of the weights:
  9 and 1 give the 200 to nine requests in ten.
- The request conditions, the `fault` and the `scenario` clause stay one
  per Stub, whichever response is picked.
- A problem in a response is reported at its JSON Pointer, with the
  response's index counted from 0, such as `/stubs/0/responses/1/json`. A
  template that fails for a request points at the field within the Stub
  the same way, such as `"at":"/responses/1/json/id"`.
- An [Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs) can give
  `responses` too, with inline bodies only: `bodyFile` is refused in any
  of them.
- The shadow warning, the Near miss and the traffic metrics look at the
  request conditions only, never at the responses.

The pick takes nothing from the Stub's random source beyond the one draw
every matched request takes (see [Helpers](#helpers)): it draws from a
generator of its own, seeded with that draw XOR a fixed constant. It draws
a number below the sum of the weights, each equally likely, and takes the
response whose share of the running total holds it, in the order written.
So the Fault decisions and the helper output for a seed are the same with
`responses` as with `response`, and [`fault.seed` and `--seed`](#seeds)
replay the picks as they replay the Faults. A Stub with `response` takes no
pick.

The [Journal](../README.md#the-journal) records which response each
request got, as `responseIndex`, its index from 0. It is null for a Stub
with `response`, for a request that no Stub matched, and when no response
was picked because a value of the Stub's [`variables`](#variables) failed
to render or [the state bound](#the-state-bound) refused its writes.
`smock render` and the Admin render operation show the index the seed
picks, and `--response <i>` (the Admin API's `response=<i>`) renders the
response at index `i` ([Rendering a template](#rendering-a-template)).

## LLM responses

A response can give `llm` in place of a body, to stand in for an LLM API
in tests of code that calls one, such as an agent or a chat feature. It
declares the reply by what it says, and smock writes it in that API's wire
form, so an official SDK reads it as it reads the vendor's reply. This Stub
answers OpenAI Chat Completions requests:

```yaml
mocks:
  - name: openai
stubs:
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

An SDK reaches it through its base URL, such as
`OpenAI(base_url="http://localhost:8080/v1", api_key="test")` in
openai-python, which sends `POST /v1/chat/completions`. The request
decides the form of the reply: with `stream: true` it gets a
[stream](#streams), and otherwise one JSON body. A request for
`gpt-6-astra` without `stream` gets one `chat.completion` body, such as this
one, which [`smock render`](#rendering-a-template) shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! How can I assist you today?","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

The fields of `llm`:

| Field | Value | When left out |
|---|---|---|
| `api` | `openai-chat`, OpenAI Chat Completions; `openai-responses`, [OpenAI Responses](#openai-responses); or `anthropic-messages`, [Anthropic Messages](#anthropic-messages) | required |
| `text` | the text of the reply | empty |
| `chunks` | the text as a list of at least one piece, in place of `text` | — |
| `chunkSize` | code points per piece of a stream, an integer from 1 to 1,000,000 | 4 |
| `toolCalls` | a list of [tool calls](#tool-calls), each `{name, arguments, id}` | none |
| `id` | the reply's id, sent as written | generated |
| `model` | the reply's model | the request's |
| `usage` | `{input, output}`, token counts, integers from 0 to 2^53-1 | both 0 |
| `stopReason` | a stop reason of the API, such as `length` | derived |
| `timing` | `{first, interval}`, the [waits of a stream](#timing), each a distribution of the [delay](#delays) | no waits |
| `error` | `{after, type, message}`, or `{after, code, message}` for `openai-responses`: a [mid-stream error](#mid-stream-errors) | none |

- `api` names the API whose wire form the reply takes. It is required, and
  smock never infers it from the request's path, so a proxy or a base path
  of its own does not change the reply. The preset neither sets nor checks
  `request.path`: the Stub's conditions choose it, as for any Stub.
- An `openai-chat` reply is the assistant's message, with `text` as its
  `content`, or `""` when the text is empty, then its
  [tool calls](#tool-calls), and the [stop reason](#usage-and-stop-reasons)
  as its `finish_reason`. With tool calls and empty text, `content` is
  `null`. Its fields
  and their order follow the example of OpenAI's API reference, and so do
  its fixed values, such as `refusal: null` and `service_tier: "default"`.
  `usage` has the example's members, with the
  [declared counts](#usage-and-stop-reasons) and every other count 0. There
  is no `system_fingerprint`.
- An `openai-responses` reply is a Response object, with `text` in its
  message item and each tool call in a `function_call` item.
  [OpenAI Responses](#openai-responses) says more.
- An `anthropic-messages` reply is a `message` object, with `text` in its
  text block and each tool call in a `tool_use` block.
  [Anthropic Messages](#anthropic-messages) says more.
- smock sets `Content-Type: application/json`, or `text/event-stream` for
  a stream. A `Content-Type` the Stub gives is replaced, as for `events`.
  smock also adds an `x-request-id` header, or `request-id` for
  `anthropic-messages`, unless the Stub gives its own.
  Other headers, such as a rate-limit header, are sent as written.
- The reply's id is generated with the vendor's prefix, unless `id` fixes
  it. `created`, or Responses' `created_at`, is the time smock received the
  request. `model` is the Stub's `model`, or else the request's. [Ids,
  seeds and time](#ids-seeds-and-time) says more.

An LLM response is a response like any other. `status` is required, as
always. `llm` may stand in `response` or in any element of
[`responses`](#several-responses), so weighted responses can answer one
request in ten with an ordinary 429. Request conditions,
[templates](#templates-in-llm-replies), Faults, Ephemeral Stubs, the
Journal and [`smock render`](#rendering-a-template) work as for other
responses: a rendering shows the JSON body, or the events
for a sample whose body sets `stream: true`, with the ids and the waits its
seed gives and its time as `created`. A response gives at most one of
`body`, `bodyFile`, `json`, `events` and `llm`. A missing or unknown `api`,
an unknown field of `llm` or of its `usage`, a count that is not an integer
from 0 to 2^53-1, a stop reason that is not a word of the API, the errors
of [chunks](#chunks), of [tool calls](#tool-calls) and of a
[mid-stream error](#mid-stream-errors), a wait of `timing` that is not one
distribution of the delay, a reply as written over the
[size bound](#the-size-bound), and `llm` beside another body are reported with the JSON Pointer of the field, by `smock check`, at
startup and on a reload, which keeps the set served, and as 400
`invalid_stub` for an Ephemeral Stub.

The wire forms follow the vendors' documents as they were read on
2026-10-22 and 2026-10-23. When a vendor changes its documented form, a
minor release may change what an existing `llm` Stub sends, with a
CHANGELOG entry. CI also reads smock's replies with the vendors' official
Python SDKs, at pinned versions, as applications call them. A change that
a newer version of an SDK brings to what an existing `llm` Stub sends
ships the same way.

### Streams

A request whose body is a JSON object with `stream: true` gets the reply as
[Server-Sent Events](#server-sent-events), as the vendor streams it. Any
other request gets the JSON reply: a body that is not JSON, no `stream`,
`stream: false`, or the string `"true"`. So one Stub serves both kinds of
call, and an SDK reads the reply with the parser it chose for its own
request. Only an `llm` response reads the request body for this; other
Stubs pay nothing. An
`anthropic-messages` stream is a series of named events, which
[Messages streams](#messages-streams) lists.

An `openai-chat` stream is a series of `chat.completion.chunk` objects.
Each one is one `data:` line of compact JSON, with no `event:` line, and
every chunk carries the reply's id, `created` and model. In order:

1. the opening chunk, whose `delta` gives `role: assistant` and an empty
   `content`, or a `null` one when [tool calls](#tool-calls) follow no
   text;
2. one chunk per piece of the text, whose `delta` gives the piece as
   `content`;
3. for each [tool call](#tool-calls), a chunk that opens it, then one
   chunk per piece of its arguments;
4. the closing chunk, whose `delta` is empty and whose `finish_reason` is
   the [stop reason](#usage-and-stop-reasons);
5. when the request asks for usage, the
   [usage chunk](#usage-and-stop-reasons), with no choice;
6. `data: [DONE]`.

There is no `obfuscation` field, no `system_fingerprint` and no SSE comment
line. The text is cut into pieces of 4 code points, the last one shorter,
unless `chunkSize` or `chunks` says otherwise ([Chunks](#chunks)). The
pieces join to exactly the text, and a piece never splits a code point, so
every `data:` line is valid UTF-8. Empty text with no tool call sends the
opening and closing chunks only. A [mid-stream error](#mid-stream-errors)
ends the stream early, without the closing chunk or `[DONE]`.

For the Stub above, a request for `gpt-6-astra` with `stream: true` gets
this stream, which `smock render` shows with the same seed and time:

```text
data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o! H"},"logprobs":null,"finish_reason":null}]}

  … "ow c", "an I", " ass", "ist ", "you ", "toda" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"y?"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}

data: [DONE]

```

An `openai-responses` stream is a series of named events instead, each
with an `event:` line and a `sequence_number`, and no `[DONE]`:
[The Responses stream](#the-responses-stream) lists them.

A stream travels as the events of an `events` response do:

- smock sends the head and every event before the first piece at once,
  then each later event after the wait its [`timing`](#timing) gives.
  Without `timing`, every event follows at once.
- To an HTTP/1.1 client the stream is sent with chunked framing, so the
  connection carries the next request. An HTTP/1.0 client gets it
  unframed, and smock closes the connection to end it.
- A reply to `HEAD`, or with status 204 or 304, is the status and the
  headers alone, for the stream as for the JSON reply.
- smock plans the whole JSON body, or every event, before it applies
  [Faults](#faults). A delay holds back the status line of either. A
  `partial` Fault sends the first half of the events, rounded down, and
  does not end the stream; for the JSON reply, it sends half the body.
  `reset` and `close` are unchanged.
- The stream's [Journal](../README.md#the-journal) entry is committed
  before its last event, as for `events`.
- A client that closes the connection mid-stream ends the stream: smock
  notices when it next writes an event, and the Journal keeps the
  request's entry. A [drain](../README.md#run) on SIGTERM waits for a
  stream in progress, its waits included.

### Chunks

A stream sends the text in pieces, one chunk each. Two fields choose the
pieces, so a test can stream one code point at a time, or place a split
exactly where its parser might fail:

- `chunkSize` sets how many code points each piece holds: an integer from
  1 to 1,000,000, 4 by default. The last piece is shorter, and a size
  above the text's length sends the text as one piece.
- `chunks` gives the pieces themselves, in place of `text`: a list of at
  least one text. Each element is one piece, sent as its own chunk even
  when it is empty. The text is their join, which the JSON reply carries.
  `chunkSize` does not apply to `chunks`.

```yaml
- id: one-at-a-time
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: one-at-a-time }
  response:
    status: 200
    llm: { api: openai-chat, text: 晴れです。, chunkSize: 1 }
- id: split-emoji
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: split-emoji }
  response:
    status: 200
    llm:
      api: openai-chat
      chunks: ["Thumbs up: ", "", "👍", "🏽"]
```

The first Stub streams the content pieces `"晴"`, `"れ"`, `"で"`, `"す"`
and `"。"`. The second streams `"Thumbs up: "`, `""`, `"👍"` and `"🏽"`,
and its JSON reply's content is `"Thumbs up: 👍🏽"`.

- A piece never splits a code point, so every `data:` line is valid UTF-8,
  whatever the size. Pieces are counted in code points, not in characters
  as they show, so a piece may split a character made of several code
  points, such as a flag or an emoji with a skin tone. With `chunks`, a
  split can go between any two code points.
- An empty element of `chunks` is a piece like any other: it is sent as a
  chunk whose content is `""`.
- `text` beside `chunks`, an empty `chunks`, an element that is not a
  string, and a `chunkSize` that is not an integer from 1 to 1,000,000 are
  load errors.

### Timing

`timing` paces a stream, to test time to first token or how a UI shows a
slow reply. `first` is the wait before the first piece, and `interval` the
wait before each later one. Each takes one distribution of the
[delay](#delays) Fault, `fixed`, `uniform` or `lognormal`, in whole
milliseconds. This Stub waits about 400 ms before the first piece, and 15
to 40 ms before each later one:

```yaml
mocks:
  - name: openai
stubs:
  - id: slow-hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        timing:
          first: { lognormal: { median: 400, sigma: 0.5 } }
          interval: { uniform: { min: 15, max: 40 } }
```

- **Where the waits go.** smock writes the head and every event before the
  first piece at once. It waits `first` before the first event that
  carries a piece, counted from the head, and `interval` before each later
  one. The events that open or close the reply, an item, a part, a
  [tool call](#tool-calls) or a block of an `anthropic-messages` stream
  follow the event before them at once. A piece of a tool call's arguments
  is a piece, and so is an empty element of [`chunks`](#chunks), so each
  waits as one. A reply with no piece, such as one with empty text, waits
  `first` before its first closing event: Chat's closing chunk, Responses'
  `response.output_text.done`, or the last function call's
  `response.function_call_arguments.done` when there is no message item,
  or Messages' `message_delta`. A
  [mid-stream error](#mid-stream-errors) waits as a next piece would.
- **Responses' `completed_at`.** In an `openai-responses` stream, the
  `completed_at` of `response.completed` is the time smock received the
  request plus the stream's waits up to that event, in whole seconds, so a
  slow stream completes later than it was created. `created_at` stays the
  time received. A JSON reply has no wait, so its `completed_at` is the
  time received.
- **Either may be left out**, for no wait there. Without `timing`, a stream
  has no wait at all.
- **No `probability`.** Unlike a delay, a wait applies to every stream, so
  `probability` in `first` or `interval` is a load error, as is an unknown
  distribution, a negative wait or an unknown member of `timing`.
- **Draws.** Each wait is drawn on its own, in order, from the Stub's
  random source: from a generator of its own, seeded with the one draw
  every matched request takes XOR a fixed constant, which differs from the
  ids' one. So [`fault.seed` and `--seed`](#seeds) replay a slow run
  exactly, and adding `timing` changes no id, no Fault decision, no pick
  among `responses` and no helper output.
- **Only streams.** A JSON reply is written at once, whatever `timing`
  gives. A [delay](#delays) Fault still holds back the status line of
  either, before the stream's own waits.
- **Render.** [`smock render`](#rendering-a-template) shows each event's
  wait as its `delay`, drawn as for a request. With `--seed 7` and a
  sample that sets `stream: true`, the Stub above waits 824 ms before
  `"Hell"`, then 27, 20, 38, 19, 40, 38, 26 and 28 ms before the next
  eight pieces. The opening chunk, the closing chunk and `[DONE]` wait 0.
  The same Stub with `api: openai-responses` waits the same 1060 ms in
  all, so with `--time 2026-10-23T00:00:00Z` its `response.completed`
  gives `completed_at` 1792713601, one second after its `created_at`.

### Usage and stop reasons

`usage` declares the token counts the reply reports, and `stopReason` why
the reply ended. This Stub stands for a reply cut short by the token limit:

```yaml
mocks:
  - name: openai
stubs:
  - id: truncated
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: The weather in Paris is
        usage: { input: 31, output: 5 }
        stopReason: length
```

smock counts no tokens and estimates none: the reply reports the counts
as written. Each one is an integer from 0 to 2^53-1, 9007199254740991, and
0 when left out. An [`openai-responses`](#openai-responses) reply gives
them as `input_tokens` and `output_tokens`, with `total_tokens` their sum.
An `anthropic-messages` reply gives them as `input_tokens` and
`output_tokens`, with no total and no cache counts. Its stream gives
`input_tokens` in `message_start`, with `output_tokens` 0, and
`output_tokens` in `message_delta`. An `openai-chat` reply
gives `input` as `prompt_tokens`, `output` as `completion_tokens`, and
their sum as `total_tokens`. The detail objects of OpenAI's example
follow, every count in them 0. A request
for `gpt-6-astra` without `stream` gets this reply, which `smock render`
shows with `--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"The weather in Paris is","refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"length"}],"usage":{"prompt_tokens":31,"completion_tokens":5,"total_tokens":36,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

The JSON reply always carries `usage`. An `openai-chat` [stream](#streams)
carries it only when the request asks for it, as the vendor's does:

- When the request's body sets `stream_options.include_usage` to `true`,
  every chunk carries `"usage":null`. After the closing chunk comes the
  usage chunk, whose `choices` is empty and whose `usage` gives the counts,
  then `data: [DONE]`. An SDK reads the counts from that last chunk.
- Any other stream has no `usage` member and no usage chunk. That includes
  `include_usage: false` and the string `"true"`.

The same request with `stream: true` and
`stream_options: { include_usage: true }` gets a stream that ends with
these events:

```text
  … "The ", "weat", "her ", "in P", "aris" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":" is"},"logprobs":null,"finish_reason":null}],"usage":null}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"length"}],"usage":null}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[],"usage":{"prompt_tokens":31,"completion_tokens":5,"total_tokens":36,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}

data: [DONE]

```

`stopReason` is written in the word of the Stub's API:

- For `openai-chat` it is the `finish_reason`, one of `stop`, `length`,
  `tool_calls`, `content_filter` and `function_call`, which OpenAI
  deprecates. It goes in the JSON reply's `finish_reason` and in the
  closing chunk's.
- For `openai-responses`, which has no stop word, it is an incomplete
  reason, one of `max_output_tokens`, `max_messages`, `content_filter` and
  `steered`, which makes the reply [incomplete](#incomplete-replies).
- For `anthropic-messages` it is the `stop_reason`, one of `end_turn`,
  `max_tokens`, `stop_sequence`, `tool_use`, `pause_turn`, `refusal` and
  `model_context_window_exceeded`. It goes in the JSON reply's
  `stop_reason` and in the stream's `message_delta`. `stop_sequence` and
  `refusal` each add a member to both
  ([Anthropic Messages](#anthropic-messages)).
- Any word of the API may be written, whatever the reply holds. So a test
  can send `length` for a reply cut short, or `content_filter` for a
  filtered one.
- Left out, smock derives it from the reply: for `openai-chat`,
  `tool_calls` when the reply has [tool calls](#tool-calls) and `stop`
  otherwise; for `anthropic-messages`, `tool_use` when the reply has tool
  calls and `end_turn` otherwise. An `openai-responses` reply is then
  `completed`.
- A word that is not one of the API's, such as Anthropic's `end_turn` on
  `openai-chat`, or Chat's `length` on `openai-responses`, is a load error
  that lists the API's words. smock checks it when it loads the Stub, so a
  reply never carries a word its SDK does not know.

### Ids, seeds and time

smock generates ids for each reply: the reply's id, the id of each item
the reply holds and of each [tool call](#tool-calls), and a request id,
which it sends in a header. Each is the vendor's prefix and 24 characters
from `A`-`Z`, `a`-`z` and `0`-`9`:

| API | Reply's id | Items and tool calls | Request-id header |
|---|---|---|---|
| `openai-chat` | `chatcmpl-` | tool call `call_` | `x-request-id: req_…` |
| `openai-responses` | `resp_` | message item `msg_`, function call `fc_`, its `call_id` `call_` | `x-request-id: req_…` |
| `anthropic-messages` | `msg_` | tool use `toolu_` | `request-id: req_…` |

- One reply has one id: the JSON reply and every event of the stream carry
  the same one.
- The ids come from the Stub's random source: from a generator of their
  own, seeded with the one draw every matched request takes XOR a fixed
  constant. So [`fault.seed` and `--seed`](#seeds) replay them, and an
  `llm` response changes no Fault decision, no pick among `responses` and
  no helper output.
- A seeded Stub's generator advances once per request the Stub matches,
  whatever the Session. So the n-th request it matches gets the same ids
  in every run. Which request is the n-th depends on the order the
  requests arrive in, such as when tests run in parallel. A test that
  must know an id in advance fixes it.
- `id` fixes the reply's id. smock sends it exactly as written, with no
  prefix, in the JSON reply and in every event of the stream. Fixing it
  changes no other id: the ids draw in a fixed order of slots, the reply's
  first, then the Responses message item's, then two for each tool call,
  and the request id's last. Every slot draws whether or not the Stub
  fixes its id, or its API uses it. So adding `id` to a Stub keeps the
  request ids of a recorded run, and a Stub that moves from `openai-chat`
  to `openai-responses` keeps the 24 characters of its reply's id and its
  request id.
- The Responses message item's `msg_` id and a function call item's `fc_`
  id are always generated: no field fixes them.
- `created`, and Responses' `created_at`, is the time smock received the
  request, in whole seconds since the Unix epoch: the time `now()` reads.
  In a rendering, it is the rendering's time.
- The reply's `model` is the Stub's `model` when given. Otherwise it is the
  request's `model` when that is a string, and otherwise the empty string,
  such as when the body is not JSON. `llm` adds no condition on the model,
  so one Stub answers every model. A Stub that should answer one model
  adds a body condition on it, as below.
- smock adds the request-id header to the JSON reply and to the stream,
  after the Stub's own header fields. openai-python and
  anthropic-sdk-python each read it as the reply's `_request_id`. A header
  the Stub gives under that name, in any case, takes its place: smock then
  sends the Stub's field alone. The request id still draws its slot, so no
  other id changes.

This Stub answers only requests for `gpt-6-astra`, and fixes the reply's
id, its model and its request id, so that a test can assert all three:

```yaml
mocks:
  - name: openai
stubs:
  - id: astra
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { model: gpt-6-astra } }
    response:
      status: 200
      headers: { x-request-id: req_test_1 }
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        id: chatcmpl-test-1
        model: gpt-6-astra-2026-10-01
```

A request for `gpt-6-astra` gets a reply that begins
`{"id":"chatcmpl-test-1","object":"chat.completion","created":…,"model":"gpt-6-astra-2026-10-01",`,
with `x-request-id: req_test_1`. A request for another model does not
match it.

### Tool calls

`toolCalls` declares the function tool calls of the reply, so that an
agent's tool loop runs against smock. This Stub answers a conversation
whose [last message](#operators-in-json-conditions) is the user's with
text and a call of `get_weather`:

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/chat/completions
      body: { json: { messages: { $last: { role: user } } } }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Let me check.
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
        usage: { input: 31, output: 18 }
```

Each tool call has these fields:

| Field | Value | When left out |
|---|---|---|
| `name` | the function's name, non-empty text | required |
| `arguments` | a JSON object, or a string sent as written | required |
| `id` | the call id, sent as written | generated |

- The text comes first, then each tool call in the order written.
- An object in `arguments` is written as compact JSON, its members in the
  order written and its numbers as a `json` body writes them. A string is
  sent exactly as written, so a test can send
  [arguments that are not valid JSON](#broken-arguments).
- smock checks no `name` against a vendor's naming rule, and no
  `arguments` against the request's `tools`.
- With tool calls, empty text gives no content: `content` is `null` in the
  JSON reply and in the stream's opening chunk, and no chunk carries
  content, even when `chunks` gives empty pieces. So openai-python's
  stream helper builds the same message from the stream as from the JSON
  reply. An `openai-responses` reply has no message item then, and an
  `anthropic-messages` reply no text block.
- Left out, the [stop reason](#usage-and-stop-reasons) is `tool_calls`, or
  `tool_use` for `anthropic-messages`. A written one is sent whatever the
  reply holds.
- A missing `name` or `arguments`, an empty `name`, `arguments` that are
  neither an object nor a string, an unknown field of a tool call, and two
  tool calls of one `llm` with the same `id` are load errors. With
  [templates](#templates-in-llm-replies), ids that insert a value are
  compared after rendering.
- `openai-responses` sends them as
  [function call items](#function-call-items), and `anthropic-messages` as
  `tool_use` blocks ([Messages tool calls](#messages-tool-calls)).

A request for `gpt-6-astra` without `stream` gets this reply, which
`smock render` shows with `--seed 7` and `--time 2026-10-23T00:00:00Z`.
The message gives `tool_calls` after its content, each call's arguments
as a JSON string:

```json
{"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}],"refusal":null,"annotations":[]},"logprobs":null,"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":31,"completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"service_tier":"default"}
```

In a [stream](#streams), the text's pieces come first. Then each tool
call, counted from 0 as its `index`, opens with a chunk that gives its
`index`, its call id, `type: function`, its name and empty arguments. One
chunk follows per piece of its arguments, with the `index` and the piece
alone. The arguments are cut as the text is, into pieces of `chunkSize`
code points, 4 by default; `chunks` does not apply to them. Every
tool-call chunk carries the integer `index`, so openai-python joins the
pieces of each call. The same request with `stream: true` gets these
events after the text's pieces:

```text
  … "Let ", "me c", "heck", "." …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_oLxN2ar43pJJV6rqKHXsG45M","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]},"logprobs":null,"finish_reason":null}]}

  … "ty\":", "\"Par" …

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\"}"}}]},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}

data: [DONE]

```

Call ids follow the rules of [Ids, seeds and time](#ids-seeds-and-time):

- A tool call's call id is `call_` and 24 characters, or `toolu_` and 24
  characters for `anthropic-messages`, the same in every event of a
  stream, unless `id` fixes it. smock sends a fixed id exactly as written,
  with no prefix.
- Each tool call draws two slots of the ids' order, after the reply's and
  before the request id's. `openai-chat` sends the second as the call id.
  `openai-responses` sends the first as its function call item's `fc_` id
  and the second as its `call_id`. `anthropic-messages` sends the second
  as the `tool_use` id. So a Stub that moves between the APIs keeps the 24
  characters of each call id. Adding a tool call changes the request id,
  and not the reply's id.
- A fixed `id` still draws its slots, so fixing one call id changes no
  other id.
- The call ids of one reply must differ, so two tool calls of one `llm`
  with the same `id` are a load error. Templated ids that render the same
  give the [template error](#templates-in-llm-replies) 500.

When the agent sends the tool's result back, a second Stub answers it. A
condition on the last message tells the turns apart, as the
[`$last` examples](#operators-in-json-conditions) show for each API:

```yaml
- id: answer-weather
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    body: { json: { messages: { $last: { role: tool } } } }
  response:
    status: 200
    llm: { api: openai-chat, text: It is 18°C in Paris. }
```

#### Broken arguments

A model can send arguments that are not valid JSON, and an agent should
survive them. Give `arguments` as a string to send it exactly as written:

```yaml
- id: broken-arguments
  mock: openai
  request:
    method: POST
    path: /v1/chat/completions
    headers: { X-Test-Case: broken-arguments }
  response:
    status: 200
    llm:
      api: openai-chat
      toolCalls:
        - name: get_weather
          arguments: '{"city": "Par'
```

The JSON reply's call has `"arguments":"{\"city\": \"Par"`, and a stream
sends the same text in pieces. smock does not check it. Checked with
openai-python 3.36.1: `chat.completions.create()` returns the arguments as
the string they are, so the agent's own `json.loads` raises
`JSONDecodeError`. `chat.completions.parse()` and the
`chat.completions.stream()` helper parse the arguments of a strict
function tool, such as one made with `openai.pydantic_function_tool`, and
raise pydantic's `ValidationError`.

Under `api: anthropic-messages`, the vendor's `input` is always an object,
and smock sends a string that holds a JSON object as that object. Any
other string, such as this one, is sent as a JSON string: the JSON reply's
`tool_use` block has `"input":"{\"city\": \"Par"`. A stream sends the
text as written, in `partial_json` pieces, so a client that reads the raw
events sees it exactly. The vendor never sends such a stream. Checked with
anthropic-sdk-python 2.1.0:

- `messages.create()` returns the string as the block's `input`. With
  `stream=True`, it yields the events with their pieces as written.
- `messages.stream()` parses the pieces of each block as they arrive, as
  partial JSON. On arguments that are not JSON, such as `not JSON`, it
  raises `ValueError` mid-stream, as it would on such a vendor stream.
- JSON cut short, such as the Stub's above, is no error to it: the block's
  `input` is what has arrived whole, here `{}`.

### Mid-stream errors

`error` cuts a stream short with the API's own error, after part of the
text, so a test can check how its client handles a model that fails
mid-reply, such as an overloaded one. This Stub sends `Hello`, then an
error:

```yaml
mocks:
  - name: openai
stubs:
  - id: cut-short
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
        error:
          after: 5
          type: server_error
          message: The server had an error while processing your request. Sorry about that!
```

The fields of `error`:

| Field | Value | When left out |
|---|---|---|
| `after` | how many code points of the text come before the error, an integer from 0 | 0 |
| `type` | the error's type: non-empty text, or for `anthropic-messages` one of Anthropic's error types | required |
| `code` | in place of `type`, for `openai-responses` only: the error's code, non-empty text | required |
| `message` | the error's message, non-empty text, a template with `template: true` | required |

- **What is sent.** A request with `stream: true` gets the opening chunk,
  then the text's pieces up to exactly `after` code points, the piece that
  holds the cut ending there, then the error. The stream ends there. No
  tool call, closing chunk, usage chunk or `[DONE]` follows, so the client
  sees an interrupted stream.
- **Chat's form.** For `openai-chat`, the error is a `data:` line of its
  own, in place of a chunk:
  `{"error":{"message":…,"type":…,"param":null,"code":null}}`.
- **Counted in code points.** `after` counts code points of the text, not
  pieces, so the cut stays where it is when `chunkSize` or `chunks`
  changes. `after: 0` sends the error right after the opening chunk. An
  empty element of [`chunks`](#chunks) counts 0 code points: one before
  the cut is sent, and the text stops at the piece that reaches `after`.
  An `after` past the end of a text as written is a load error.
- **With templates.** With [`template: true`](#templates-in-llm-replies),
  `message` is a text template, such as `Overloaded: ${body.model}`,
  rendered for each request. `after`, `type` and `code` are never
  templates. A templated text is known only once it is rendered, so an
  `after` past its end is no load error: when the rendered text is
  shorter than `after`, the error follows the whole text. A message that
  renders empty is sent empty.
- **Waits.** The error waits as a next piece would: `first` when no piece
  came before it, and `interval` otherwise ([Timing](#timing)).
- **Only streams.** A request that does not stream gets the ordinary
  reply, whole, so one Stub serves both. smock keeps no table of statuses:
  an error in place of the whole reply is an ordinary response
  ([Errors before the reply](#errors-before-the-reply)).
- **Status and Journal.** The status is the Stub's, 200 here, sent before
  the stream starts. The [Journal](../README.md#the-journal) entry has
  that status, and is committed before the last event, the error, as for
  `events`.
- **What openai-python does.** It raises `APIError` on Chat's error frame,
  from `create(stream=True)` and from the `chat.completions.stream()`
  helper, with the message, and the `error` object as its `body`. With
  `max_retries` at its default it does not retry: the status was 200.
  Checked with openai-python 3.36.1.
- **Per API.** `openai-chat` and `anthropic-messages` give `type`, and
  `openai-responses` gives `code`, as each API names it. So the other one
  is a load error that names the member to give, and a Stub that moves to
  another `api` renames it there. Anthropic's `type` is one of its
  documented error types: `invalid_request_error`,
  `authentication_error`, `billing_error`, `permission_error`,
  `not_found_error`, `conflict_error`, `request_too_large`,
  `rate_limit_error`, `api_error`, `timeout_error` and
  `overloaded_error`. An OpenAI `type` or `code` is any non-empty text.
- **For now,** only `openai-chat` cuts its stream. An `openai-responses`
  or `anthropic-messages` Stub reads and checks `error`, and sends its
  reply whole.
- `type` on `openai-responses` or `code` on another API, another
  Anthropic type, an empty `type`, `code` or `message`, an `after` that is
  not an integer from 0 or that passes the end of a text as written, and an
  unknown field of `error` are load errors.

A request for `gpt-6-astra` with `stream: true` gets this stream, which
[`smock render`](#rendering-a-template) shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`. The second piece, `"o! H"` without the
error, ends at the cut:

```text
data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"Hell"},"logprobs":null,"finish_reason":null}]}

data: {"id":"chatcmpl-oniRcSDFUU6bnxe66XwQR5pl","object":"chat.completion.chunk","created":1792713600,"model":"gpt-6-astra","choices":[{"index":0,"delta":{"content":"o"},"logprobs":null,"finish_reason":null}]}

data: {"error":{"message":"The server had an error while processing your request. Sorry about that!","type":"server_error","param":null,"code":null}}

```

### Templates in LLM replies

With [`template: true`](#templates), an LLM reply is rendered for each
request, so it can echo the request, or read a [Variable](#variables) or
a [Data bucket](#data-buckets). This Stub echoes the user's last message:

```yaml
mocks:
  - name: openai
stubs:
  - id: echo
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      template: true
      llm:
        api: openai-chat
        text: 'You said: ${last(body.messages).content}'
```

A request whose last message is `Say "hi"`, a line break and `then stop`
gets a reply whose message has
`"content":"You said: Say \"hi\"\nthen stop"`. With `stream: true`, the
pieces are `You `, `said`, `: Sa`, `y \"h`, `i\"\nt`, `hen ` and `stop`,
as `smock render` shows with `--seed 7`.

- `text`, each element of `chunks`, `id`, `model`, each tool call's
  `name`, `id` and string `arguments`, and the
  [error's](#mid-stream-errors) `message` are text templates. An object
  `arguments` is a [structured template](#structured-templates), whose
  members keep the types of what they insert. `api`, `stopReason`,
  `usage`, `chunkSize`, `timing`, and the error's `after`, `type` and
  `code` are never templates. Header values are templates, as in any
  response.
- smock renders the text whole for each request, then cuts it into
  pieces, so echoed text is cut like any other. Each element of `chunks`
  is rendered on its own and stays one piece. A tool call's arguments are
  rendered, then cut.
- These templates escape nothing. smock writes what they give into the
  JSON it builds, so a quote or a line break from the request is
  JSON-escaped on the wire, whatever the Stub's `Content-Type`. An object
  or an array in a text template needs `json(x)`, as in any text template.
- Helpers, such as `fake.uuid()`, draw in render order: the header values,
  then `id`, `model`, the text or each chunk in order, each tool call's
  `id`, `name` and `arguments`, then the error's `message`. So
  [`fault.seed`](#seeds) replays them, and adding an error changes nothing
  drawn before it. The generated ids draw from a generator of their own,
  so a helper changes none of them.
- The templates read `vars` and `data` as any response's do: after the
  Stub's [`variables`](#variables) and [`dataWrites`](#writing-buckets-datawrites)
  have written, so the reply reads what they just did. A Scenario moves on
  an `llm` Stub as on any other.
- A syntax error is a load error at the field's JSON Pointer, such as
  `/stubs/0/response/llm/text`. Two tool calls whose ids insert nothing
  and are the same are a load error, as without templates. Ids that
  insert a value are compared after rendering.

This Stub's calls take the user's last message and the whole
conversation:

```yaml
- id: search
  mock: openai
  request: { method: POST, path: /v1/chat/completions }
  response:
    status: 200
    template: true
    llm:
      api: openai-chat
      toolCalls:
        - name: search
          arguments: { query: "${last(body.messages).content}", limit: "${body.limit ?? 5}" }
        - name: log
          arguments: '{"messages":${json(body.messages)}}'
```

For the request above, the first call's arguments are
`{"query":"Say \"hi\"\nthen stop","limit":5}`, and the second's
`{"messages":[{"role":"user","content":"Say \"hi\"\nthen stop"}]}`.

A template that fails to render, such as one that inserts a missing
value, gives the usual [500 `template failed`](#missing-values-and-render-errors),
with `at` under the `llm` field, such as
`"at":"/response/llm/text","message":"body.messages is missing"`. Two tool
call ids that render the same give it too. A streamed request gets the
500, not a stream, since smock renders the whole reply before it sends
the head. Every template renders for every request, so an error's
`message` that fails gives the 500 to a request that does not stream too.

The SDKs [retry](#retries) a 500 twice by default. So one call to a Stub
whose template fails makes three requests, with three Journal entries,
and takes three draws from a seeded Stub's random source: the requests
after it get other ids and waits than in a run without the failure. A
test that expects the 500 builds its client with `max_retries=0`.

### The size bound

An LLM reply takes at most 1 MiB once encoded: its JSON body, or all the
events of its stream, with their `event:` and `data:` lines and blank
lines, in UTF-8. This is the bound of a
[rendered body](#missing-values-and-render-errors), counted on its own:
the strings that a template renders keep their own count.

A stream carries much more than its text. Each piece goes in an event of
its own, and every Chat chunk repeats the reply's id and model. At 4 code
points per piece, a stream of ASCII text reaches 1 MiB at about 20,000
characters for `openai-chat` and `openai-responses`, and at about 35,000
for `anthropic-messages`. A larger `chunkSize` lets a stream carry more.
The JSON reply carries the text once, so it holds almost 1 MiB of it.

- A reply as written is encoded when the files are loaded, both as the
  JSON reply and as the stream to a request whose body is
  `{"stream":true,"stream_options":{"include_usage":true}}`, with no model
  from the request. Either one over the bound is a load error at the
  `llm` field, which `smock check` reports, such as
  `/stubs/0/response/llm: the reply takes more than 1 MiB as a stream`.
  A [mid-stream error](#mid-stream-errors) ends the stream early, so then
  the JSON reply can be the larger: a long text cut early loads, unless
  its JSON reply alone passes the bound.
- A reply can still pass the bound for one request. A template can insert
  a long value, in the text or in an error's `message`, and a long `model`
  from the request, or a setting that a Responses object copies, such as
  `tools`, goes into the reply. A Responses stream carries those settings
  three times. Such a request gets
  the [500 `template failed`](#missing-values-and-render-errors), with
  `at` at the `llm` field, and no stream:
  `"at":"/response/llm","message":"the reply takes more than 1 MiB as a stream"`.
  The SDKs [retry](#retries) it, as any 500.
- smock stops encoding a reply as soon as it passes the bound, so a long
  echo costs no more than a reply of 1 MiB.

### OpenAI Responses

`api: openai-responses` answers OpenAI's Responses API with a Response
object. This Stub answers it at its path, `/v1/responses`:

```yaml
mocks:
  - name: openai
stubs:
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/responses }
    response:
      status: 200
      llm:
        api: openai-responses
        text: Hi there! How can I assist you today?
        usage: { input: 37, output: 11 }
```

openai-python reaches it through the same base URL as Chat Completions,
`OpenAI(base_url="http://localhost:8080/v1", api_key="test")`. Then
`client.responses.create(model="gpt-6-astra", instructions="You are a helpful assistant.", input="Hello!")`
sends `POST /v1/responses`, and gets this reply, which
[`smock render`](#rendering-a-template) shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}}
```

- `output` holds the message item, with `text` as its `output_text`, or
  `""` when the text is empty. Its id is `msg_` and 24 generated
  characters. Each [tool call](#function-call-items) follows it as a
  `function_call` item. With tool calls and empty text, there is no
  message item.
- `usage` gives the [declared counts](#usage-and-stop-reasons) as
  `input_tokens` and `output_tokens`, with `total_tokens` their sum.
- `created_at` and `completed_at` are the time smock received the
  request, in whole seconds. A [stream](#the-responses-stream)'s
  `completed_at` adds its waits.
- The Response object gives back the settings the request gave, copied as
  given: smock does not interpret them. They are `instructions`,
  `previous_response_id`,
  `tools`, `tool_choice`, `temperature`, `top_p`, `max_output_tokens`,
  `parallel_tool_calls`, `metadata`, `store`, `text`, `truncation`,
  `reasoning`, `user`, `safety_identifier`, `prompt_cache_key`,
  `top_logprobs`, `max_tool_calls` and `background`.
- A setting the request leaves out takes the value of OpenAI's examples,
  such as `tools: []` and `store: true`. The examples do not show the last
  five, so smock leaves them out too.
- `model` is the Stub's, or else the request's, as for every API.
  `service_tier` is always `default`, the examples' tier, and
  `conversation` is not copied.
- The other members, their order and their fixed values follow the
  examples of OpenAI's API reference, such as `error: null`,
  `access_programs: null` and `temperature: 1.0`.
- smock keeps no Responses state. `previous_response_id` is only copied,
  and a request with `background: true` gets this same reply, not a queued
  one.

#### The Responses stream

A request with `stream: true` gets the reply as a stream of named events,
as OpenAI streams it. Each event has an `event:` line equal to its `type`,
and one `data:` line of compact JSON whose `sequence_number` counts from
0, one more each time. In order:

1. `response.created`, then `response.in_progress`, each with the Response
   object in progress: `status: "in_progress"`, `output: []`,
   `usage: null` and `completed_at: null`;
2. `response.output_item.added`, which opens the message item at
   `output_index` 0, with `status: "in_progress"` and no content;
3. `response.content_part.added`, which opens its `output_text` part,
   still empty;
4. one `response.output_text.delta` per piece of the text, whose `delta`
   is the piece;
5. `response.output_text.done` with the whole `text`, then
   `response.content_part.done` with the whole part and
   `response.output_item.done` with the whole item;
6. for each [tool call](#function-call-items), its `function_call` item
   at the next `output_index`: added, its arguments in pieces, then done;
7. `response.completed` with the whole Response object, or
   `response.incomplete` when the Stub writes a stop reason
   ([Incomplete replies](#incomplete-replies)).

No `data: [DONE]` follows. The text is cut into pieces as for every API
([Chunks](#chunks)). Empty text with no tool call keeps the message item
and its part, with no delta. With tool calls, empty text gives no message
item, so steps 2 to 5 are left out. Every event carries the same `resp_`
id, and the events of an item the same item id. The Response
object of the last event is the JSON reply, but for its `completed_at`:
the time smock received the request plus the stream's waits up to that
event, in whole seconds ([Timing](#timing)). Without `timing`, that is the
time received.

For the `hello` Stub above, the same request with `stream: true` gets this
stream, which `smock render` shows with the same seed and time:

```text
event: response.created
data: {"type":"response.created","response":{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"in_progress","completed_at":null,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}

  … response.in_progress, with the same Response object …

event: response.output_item.added
data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":2}

event: response.content_part.added
data: {"type":"response.content_part.added","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]},"sequence_number":3}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"delta":"Hi t","sequence_number":4,"logprobs":[]}

  … "here", "! Ho", "w ca", "n I ", "assi", "st y", "ou t", "oday", "?" …

event: response.output_text.done
data: {"type":"response.output_text.done","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"text":"Hi there! How can I assist you today?","sequence_number":14,"logprobs":[]}

event: response.content_part.done
data: {"type":"response.content_part.done","item_id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]},"sequence_number":15}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]},"sequence_number":16}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! How can I assist you today?","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":37,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48},"user":null,"metadata":{}},"sequence_number":17}

```

openai-python reads it with `client.responses.create(..., stream=True)`,
which yields each event, or with the `client.responses.stream(...)` helper,
whose `get_final_response()` gives the Response that the JSON reply gives.

#### Function call items

An `openai-responses` reply sends each [tool call](#tool-calls) as a
`function_call` item, after its message item. This Stub answers the first
turn of an agent loop, told apart by the
[last item of `input`](#operators-in-json-conditions):

```yaml
mocks:
  - name: openai
stubs:
  - id: ask-weather
    mock: openai
    request:
      method: POST
      path: /v1/responses
      body: { json: { input: { $last: { role: user } } } }
    response:
      status: 200
      llm:
        api: openai-responses
        text: Let me check.
        toolCalls:
          - name: get_weather
            arguments: { city: Paris }
        usage: { input: 31, output: 18 }
```

`client.responses.create(model="gpt-6-astra", input=[{"role": "user", "content": "Weather in Paris?"}])`
gets this reply, which `smock render` shows with `--seed 7` and
`--time 2026-10-23T00:00:00Z`:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"completed","completed_at":1792713600,"error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Let me check.","annotations":[],"logprobs":[]}]},{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":18,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":49},"user":null,"metadata":{}}
```

- `output` holds the message item, then one item per tool call, in the
  order written, with the members of the "Functions" example of OpenAI's
  API reference: `type: function_call`, `id`, `call_id`, `name`,
  `arguments` and `status: completed`. `arguments` is a JSON string, as
  for `openai-chat`.
- With tool calls and empty text, there is no message item: `output`
  holds the function call items alone, and a stream sends no text event,
  even when `chunks` gives empty pieces. Empty text without tool calls
  keeps the message item.
- An item's `id` is `fc_` and 24 generated characters: no field fixes it.
  Its `call_id` is `call_` and 24 characters, the same ones an
  `openai-chat` reply gives the call, or the tool call's `id` as written.
  [Ids, seeds and time](#ids-seeds-and-time) says more.
- A written stop reason makes the reply [incomplete](#incomplete-replies),
  and its message item with it. The function call items stay
  `completed`.

In a stream, each tool call's item follows the message item, at the next
`output_index`:

1. `response.output_item.added`, with the item, `arguments: ""` and
   `status: "in_progress"`;
2. one `response.function_call_arguments.delta` per piece of the
   arguments, with `item_id`, `output_index` and the piece as `delta`;
3. `response.function_call_arguments.done`, with the whole `arguments`;
4. `response.output_item.done`, with the whole item, whose `id` and
   `call_id` are those of its `added`.

The arguments are cut as the text is, into pieces of `chunkSize` code
points, 4 by default; `chunks` does not apply to them. Each piece waits as
a piece of the text does ([Timing](#timing)). The closing event's Response
holds every item, as the JSON reply does. For the Stub above, the same
request with `stream: true` gets these events after the message item's:

```text
event: response.output_item.added
data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"","status":"in_progress"},"sequence_number":11}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"delta":"{\"ci","sequence_number":12}

  … "ty\":", "\"Par" …

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"delta":"is\"}","sequence_number":15}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","item_id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","output_index":1,"arguments":"{\"city\":\"Paris\"}","sequence_number":16}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_TZp9I060Mzd0w4SDwiWTe2c8","call_id":"call_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"},"sequence_number":17}

  … response.completed, whose output holds both items …
```

Checked with openai-python 3.36.1: `client.responses.create()` gives each
call as a `ResponseFunctionToolCall` in `response.output`, and the
`client.responses.stream(...)` helper's `get_final_response()` builds the
same items from the stream. When the agent sends the call's output back, a
second Stub
answers it:

```yaml
- id: answer-weather
  mock: openai
  request:
    method: POST
    path: /v1/responses
    body: { json: { input: { $last: { type: function_call_output } } } }
  response:
    status: 200
    llm: { api: openai-responses, text: It is 18°C in Paris. }
```

#### Incomplete replies

The Responses API has no stop word. For `openai-responses`, `stopReason`
is an incomplete reason instead: `max_output_tokens`, `max_messages`,
`content_filter` or `steered`. A reply that writes one is incomplete. Its
`status` is `incomplete`, `incomplete_details` gives the reason,
`completed_at` is `null`, and its message item's `status` is `incomplete`
too. A [function call item](#function-call-items) stays `completed`. Left
out, the reply is `completed`. The vendor sends `steered` only
after a steer over its WebSocket mode, which smock does not serve, and
smock accepts it as any word of the API. This Stub stands for a reply cut
short by the token limit:

```yaml
mocks:
  - name: openai
stubs:
  - id: truncated
    mock: openai
    request: { method: POST, path: /v1/responses }
    response:
      status: 200
      llm:
        api: openai-responses
        text: The weather in Paris is
        usage: { input: 31, output: 5 }
        stopReason: max_output_tokens
```

The same request gets this reply:

```json
{"id":"resp_oniRcSDFUU6bnxe66XwQR5pl","object":"response","access_programs":null,"created_at":1792713600,"status":"incomplete","completed_at":null,"error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[{"id":"msg_VV1jhq1oCsnGeHaAUIiFpgab","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"The weather in Paris is","annotations":[],"logprobs":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"service_tier":"default","store":true,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":{"input_tokens":31,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":5,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":36},"user":null,"metadata":{}}
```

A stream of an incomplete reply ends with `response.incomplete`, whose
Response object is the JSON reply above, `completed_at` null included.
openai-python's `client.responses.stream(...)` helper raises
`RuntimeError` in `get_final_response()` when the stream ends without
`response.completed`, as it does with OpenAI's own incomplete streams. So a
client reads the `response.incomplete` event instead:

```python
with client.responses.stream(model="gpt-6-astra", input="Hello!") as stream:
    for event in stream:
        if event.type == "response.incomplete":
            reason = event.response.incomplete_details.reason
```

A Stub moves between `openai-chat` and `openai-responses` by changing `api`
alone, unless it writes a stop reason that the other API does not have, or
a [mid-stream error](#mid-stream-errors). Chat's `length` on
`openai-responses` is a load error at `stopReason`, so rewrite or drop it,
and an error's `type` is a load error there, so rename it `code`. The reply's id keeps its 24 characters, with the
other API's prefix, and the request id stays the same.

### Anthropic Messages

With `api: anthropic-messages`, the reply takes the form of Anthropic's
Messages API. This Stub answers its path, `POST /v1/messages`:

```yaml
mocks:
  - name: anthropic
stubs:
  - id: hello
    mock: anthropic
    request: { method: POST, path: /v1/messages }
    response:
      status: 200
      llm:
        api: anthropic-messages
        text: Hello!
        usage: { input: 12, output: 6 }
```

anthropic-sdk-python reaches it with
`Anthropic(base_url="http://localhost:8080", api_key="test")`. The base
URL has no `/v1`, since the SDK adds it. A request for `claude-test` gets
one `message` body, such as this one, which `smock render` shows with
`--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[{"type":"text","text":"Hello!"}],"model":"claude-test","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":6}}
```

- Its members and their order follow the replies in Anthropic's guide on
  working with messages. `content` holds the text block, with the text,
  then a `tool_use` block per [tool call](#messages-tool-calls). Empty text
  with no tool call gives an empty reply: `content` is `[]`, with no block.
- `usage` gives `input` as `input_tokens` and `output` as
  `output_tokens`, with no total and no cache counts.
- The reply's id is `msg_` and 24 characters, unless `id` fixes it. smock
  adds a `request-id: req_…` header, not `x-request-id`, unless the Stub
  gives its own `request-id`. [Ids, seeds and time](#ids-seeds-and-time)
  says more.
- A request with `stream: true` gets the reply as named events
  ([Messages streams](#messages-streams)).
- Ollama's Anthropic compatibility offers the same path, so the Stub
  stands in for it too.

`stopReason` takes Anthropic's words: `end_turn`, `max_tokens`,
`stop_sequence`, `tool_use`, `pause_turn`, `refusal` and
`model_context_window_exceeded`. Left out, it is `tool_use` when the reply
has [tool calls](#messages-tool-calls), and `end_turn` otherwise. A word of
another API, such as `stop`, is a load error. Two words add a member:

- With `stop_sequence`, the reply's `stop_sequence` is the first element
  of the request's `stop_sequences`, when that is a string. Otherwise it
  is `null`, as it is with every other stop reason. smock does not search
  the text for the sequences, so it gives the first one, whichever would
  have matched.
- With `refusal`, the reply also carries
  `"stop_details":{"type":"refusal","category":null,"explanation":null}`,
  after `stop_sequence`, and so does the stream's `message_delta`. Any
  other stop reason leaves `stop_details` out.
  A refusal with empty text has no block, as the vendor's has none.

This Stub stands for a refusal, and the reply it gives:

```yaml
- id: refused
  mock: anthropic
  request:
    method: POST
    path: /v1/messages
    headers: { X-Test-Case: refused }
  response:
    status: 200
    llm: { api: anthropic-messages, stopReason: refusal }
```

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":null,"explanation":null},"usage":{"input_tokens":0,"output_tokens":0}}
```

A Stub without `stopReason` moves between `openai-chat` and
`anthropic-messages` by changing `api` alone. Its seed gives the same ids,
behind the other API's prefix: `chatcmpl-oniRcSDFUU6bnxe66XwQR5pl` becomes
`msg_oniRcSDFUU6bnxe66XwQR5pl`, a call id `call_…` becomes `toolu_…`, and
the request id stays the same, in the other header. A written stop reason
must be rewritten in the other API's word, and a
[mid-stream error](#mid-stream-errors)'s `type` must be one of Anthropic's
error types.

#### Messages streams

A request with `stream: true` gets the reply as Anthropic streams it: a
series of named events. Each event is an `event:` line that names it, then
one `data:` line of compact JSON whose `type` is the same name.
anthropic-sdk-python skips an event that has no `event:` line, so every
event has one. In order:

1. `message_start`, with the message: its id and model, no content yet,
   `stop_reason` and `stop_sequence` null, and `usage` with the
   `input_tokens`, and `output_tokens` 0;
2. for the text, a text block at `index` 0: `content_block_start`, with an
   empty text, then one `content_block_delta` per piece, whose
   `text_delta` gives the piece, then `content_block_stop`;
3. for each [tool call](#messages-tool-calls), a `tool_use` block at the
   next `index`: `content_block_start`, with the call id, the name and an
   empty `input`, then a `content_block_delta` whose `input_json_delta`
   gives an empty `partial_json`, one more per piece of the arguments,
   then `content_block_stop`;
4. `message_delta`, whose `delta` gives `stop_reason` and `stop_sequence`,
   and `stop_details` on a refusal, and whose `usage` gives the
   `output_tokens`;
5. `message_stop`.

There is no `ping` event, no SSE comment line and no `data: [DONE]`. The
text is cut into pieces as for every API ([Chunks](#chunks)). Empty text
has no text block, even when `chunks` gives empty pieces: with no tool
call, the stream is `message_start`, `message_delta` and `message_stop`,
as the JSON reply's `content` is `[]`. [`timing`](#timing) waits before
each text delta and each piece of a tool call's arguments, and a reply
with no piece waits `first` before `message_delta`. From these events,
`messages.stream()` in anthropic-sdk-python builds the message that the
JSON reply gives, and `get_final_message()` returns it, as long as each
tool call's arguments are a JSON object
([Broken arguments](#broken-arguments)).

For the `hello` Stub above, a request for `claude-test` with
`stream: true` gets this stream, which `smock render` shows with the same
seed and time:

```text
event: message_start
data: {"type":"message_start","message":{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[],"model":"claude-test","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hell"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"o!"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":6}}

event: message_stop
data: {"type":"message_stop"}

```

#### Messages tool calls

An `anthropic-messages` reply sends each of its [tool calls](#tool-calls)
as a `tool_use` block, after the text block, as the reply in Anthropic's
guide on handling tool calls does. This Stub answers with text and a call
of `get_weather`:

```yaml
- id: ask-weather
  mock: anthropic
  request:
    method: POST
    path: /v1/messages
    headers: { X-Test-Case: ask-weather }
  response:
    status: 200
    llm:
      api: anthropic-messages
      text: Let me check.
      toolCalls:
        - name: get_weather
          arguments: { city: Paris }
      usage: { input: 31, output: 18 }
```

A request for `claude-test` without `stream` gets this reply, which
`smock render` shows with `--seed 7` and `--time 2026-10-23T00:00:00Z`:

```json
{"id":"msg_oniRcSDFUU6bnxe66XwQR5pl","type":"message","role":"assistant","content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"toolu_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","input":{"city":"Paris"}}],"model":"claude-test","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":31,"output_tokens":18}}
```

- Each block is `{"type":"tool_use","id","name","input"}`, in the order
  the calls are written.
- Its id is `toolu_` and the 24 characters of the call id's slot, unless
  the call's `id` fixes it. The same Stub under `openai-chat` sends
  `call_oLxN2ar43pJJV6rqKHXsG45M`.
- `input` is an object in every reply of the vendor. An object in
  `arguments` is the `input`. A string that holds a JSON object, such as
  `'{"city": "Paris"}'`, is sent as that object. Any other string is sent
  as a JSON string ([Broken arguments](#broken-arguments)).
- With tool calls, empty text has no text block, so the first `tool_use`
  block is the first block.
- Left out, the stop reason is `tool_use`.

In a [stream](#messages-streams), each tool call is a block at the next
`index`, after the text block. `content_block_start` gives the call id,
the name and an empty `input`. A `content_block_delta` follows whose
`input_json_delta` has an empty `partial_json`, as in Anthropic's
examples, then one per piece of the arguments, then `content_block_stop`.
The arguments' text is cut into pieces of `chunkSize` code points, as the
text is; `chunks` does not apply to it. Each piece
[waits](#timing) as a piece of the text does, and the empty first one
does not. anthropic-sdk-python joins the pieces of each block and parses
them into its `input`. The same request with `stream: true` gets these
events after the text block:

```text
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_oLxN2ar43pJJV6rqKHXsG45M","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"ci"}}

  … "ty\":", "\"Par" …

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"is\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":18}}

event: message_stop
data: {"type":"message_stop"}

```

### Paths and compatible endpoints

The preset neither sets nor checks `request.path`. A Stub's conditions
decide which requests it answers, as for any Stub, and smock checks no
request against a vendor's schema. So `openai-chat` also stands in for
the services that offer Chat Completions to OpenAI's SDKs at paths of
their own. Give the Stub the service's path, and point the client's base
URL at smock with the same path, such as
`http://localhost:8080/v1beta/openai/` for Gemini:

| Service | Its base URL | The Stub's path |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | `/v1/chat/completions` |
| Gemini, OpenAI compatibility | `https://generativelanguage.googleapis.com/v1beta/openai/` | `/v1beta/openai/chat/completions` |
| Anthropic, OpenAI SDK compatibility | `https://api.anthropic.com/v1/` | `/v1/chat/completions` |
| Ollama, OpenAI compatibility | `http://localhost:11434/v1/` | `/v1/chat/completions` |

Gemini's own `generateContent` and Ollama's own `/api/chat` have other
wire forms, which `llm` does not write. `openai-responses` stands in the
same way for the Responses API, at `/v1/responses` under OpenAI's base URL,
or under Ollama's, whose OpenAI compatibility serves it too.

Azure OpenAI puts the deployment's name in the path. For
`model="my-gpt"`, openai-python's
`AzureOpenAI(azure_endpoint="http://localhost:8080", api_version="2024-10-21", api_key="test")`
sends `POST /openai/deployments/my-gpt/chat/completions?api-version=2024-10-21`.
A path pattern answers every deployment. The query does not count, since
the Stub lists no query parameter:

```yaml
mocks:
  - name: azure
stubs:
  - id: azure-chat
    mock: azure
    request:
      method: POST
      path: { pattern: "/openai/deployments/[^/]+/chat/completions" }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

The reply is in OpenAI's form. It has none of Azure's content-filter
members, such as `prompt_filter_results` and `content_filter_results`.

### Errors before the reply

`llm` declares a reply that succeeds, or one that a
[mid-stream error](#mid-stream-errors) cuts short. An error that comes in
place of the reply, such as a 429 or a 529, is an ordinary response with
the vendor's error body. Each vendor has one shape:

- OpenAI: `{"error": {"message", "type", "param", "code"}}`. All four
  members are present, and `param` and `code` may be `null`. A 429 or a
  503 may carry `Retry-After`, in seconds. Every reply carries an
  `x-request-id` header.
- Anthropic: `{"type": "error", "error": {"type", "message"},
  "request_id"}`. Every reply carries a `request-id` header, with the same
  id as `request_id`. Some 429s carry `retry-after`. The error's `type`
  follows the status:

  | Status | `error.type` |
  |---|---|
  | 400 | `invalid_request_error` |
  | 401 | `authentication_error` |
  | 402 | `billing_error` |
  | 403 | `permission_error` |
  | 404 | `not_found_error` |
  | 409 | `conflict_error` |
  | 413 | `request_too_large` |
  | 429 | `rate_limit_error` |
  | 500 | `api_error` |
  | 504 | `timeout_error` |
  | 529 | `overloaded_error` |

smock adds no request-id header to an ordinary response, only to an
`llm` reply, so the recipes below write one. Their messages and ids are
examples. The SDKs choose the error they raise by the status, such as
`RateLimitError` for a 429, and keep the body in it.

#### Retries

The official SDKs, openai-python and anthropic-sdk-python, retry a
request that gets 408, 409, 429 or any 5xx, twice by default, so one call
can make three requests. Before each retry they wait out the reply's
`Retry-After`: openai-python up to 120 s, and it does not retry when asked
to wait longer. Without one, they back off from about half a second. Both
obey `x-should-retry`: with `false`, they do not retry, whatever the
status. So that a test sees each error once and does not wait, either:

- build the client with `max_retries=0`, such as
  `OpenAI(base_url="http://localhost:8080/v1", api_key="test", max_retries=0)`
  or `Anthropic(base_url="http://localhost:8080", api_key="test", max_retries=0)`;
- or send `x-should-retry: "false"` in the Stub's headers. Quote it: a
  header value is a string, and YAML reads a bare `false` as a boolean.

Each retry is a request of its own: it matches a Stub, takes a draw from
the Stub's random source, and gets its own Journal entry.

#### A 401 without a key

smock ignores `Authorization`, `x-api-key` and `anthropic-version`, as it
ignores every header a Stub does not list, so any key works, such as
`api_key="test"`. A test that needs a 401 adds an ordinary Stub with a
`headers` condition, declared before the Stubs it guards:

```yaml
mocks:
  - name: openai
stubs:
  - id: no-key
    mock: openai
    request:
      headers: { Authorization: { $exists: false } }
    response:
      status: 401
      headers: { x-request-id: req_eTuAaXsuWSSRENWrCE3JNEi7 }
      json:
        error:
          message: Incorrect API key provided.
          type: invalid_request_error
          param: null
          code: invalid_api_key
  - id: hello
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
```

Anthropic's API takes its key in `x-api-key` or in `Authorization`, so
its Stub checks both:

```yaml
- id: no-key
  mock: anthropic
  request:
    headers:
      x-api-key: { $exists: false }
      Authorization: { $exists: false }
  response:
    status: 401
    headers: { request-id: req_KEdIon5S7matgpJr8lPWEQTb }
    json:
      type: error
      error: { type: authentication_error, message: Invalid API key. }
      request_id: req_KEdIon5S7matgpJr8lPWEQTb
```

To refuse every key but the test's own, write a condition such as
`{ $not: "Bearer sk-test" }` in place of `{ $exists: false }`. Both SDKs
raise `AuthenticationError` for a 401, and neither retries it
([Retries](#retries)).

#### A 429 with Retry-After

```yaml
mocks:
  - name: openai
stubs:
  - id: rate-limited
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 429
      headers:
        Retry-After: "20"
        x-request-id: req_5K5eWPUAGI1WXJRVsFgWLtIw
        x-should-retry: "false"
      json:
        error:
          message: Rate limit reached for requests.
          type: rate_limit_error
          param: null
          code: slow_down
```

Both SDKs retry a 429 twice by default, as they retry 408, 409 and every
5xx, after waiting out its `Retry-After`, openai-python up to 120 s
([Retries](#retries)). Both obey `x-should-retry: "false"`, so
openai-python raises `RateLimitError` at once. Without it, the call would
wait 20 s twice and raise only after the third 429. `max_retries=0` on the
client does the same for every Stub. Anthropic's 429 has the `error.type`
`rate_limit_error`.

To rate-limit one call in ten, give the 429 beside an `llm` reply in
[weighted responses](#several-responses):

```yaml
- id: chat
  mock: openai
  request: { method: POST, path: /v1/chat/completions }
  responses:
    - weight: 9
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
    - weight: 1
      status: 429
      headers:
        Retry-After: "1"
        x-request-id: req_5K5eWPUAGI1WXJRVsFgWLtIw
        x-should-retry: "false"
      json:
        error:
          message: Rate limit reached for requests.
          type: rate_limit_error
          param: null
          code: slow_down
  fault: { seed: 7 }
```

With its retries on, an SDK would retry the 429 and most likely get the
reply, so the code under test would not see it. `x-should-retry: "false"`
keeps the 429 for the code under test, and `fault.seed` gives the 429 to
the same calls on every run.

#### A 529 when overloaded

Anthropic answers 529 when its API is overloaded:

```yaml
mocks:
  - name: anthropic
stubs:
  - id: overloaded
    mock: anthropic
    request: { method: POST, path: /v1/messages }
    response:
      status: 529
      headers: { request-id: req_5J4ymbACTcA49ramAi1T8pGa }
      json:
        type: error
        error: { type: overloaded_error, message: Overloaded }
        request_id: req_5J4ymbACTcA49ramAi1T8pGa
```

A 529 is a 5xx, so both SDKs retry it twice by default, as they retry
408, 409 and 429, after waiting out a `Retry-After`, openai-python up to
120 s. Both obey `x-should-retry: "false"` in the Stub's headers
([Retries](#retries)). With
`Anthropic(base_url="http://localhost:8080", api_key="test", max_retries=0)`,
anthropic-sdk-python raises `OverloadedError` at once. OpenAI's counterpart
is a 503, with `type: service_unavailable_error` and
`code: server_is_overloaded`, which may carry `Retry-After`. openai-python
raises `InternalServerError` for it.

### Model lists and other paths

`llm` writes only the reply to a prompt. Ordinary `json` Stubs answer the
rest of an API, such as its model list, `GET /v1/models`. In OpenAI's
shape:

```yaml
- id: models
  mock: openai
  request: { method: GET, path: /v1/models }
  response:
    status: 200
    json:
      object: list
      data:
        - { id: gpt-6-astra, object: model, created: 1792713600, owned_by: system }
```

In Anthropic's shape:

```yaml
- id: models
  mock: anthropic
  request: { method: GET, path: /v1/models }
  response:
    status: 200
    json:
      data:
        - { type: model, id: claude-test, display_name: Claude Test, created_at: "2026-10-01T00:00:00Z", lifecycle: active }
      has_more: false
      first_id: claude-test
      last_id: claude-test
```

A request that no Stub matches gets smock's own `noMatch` reply, a 404 with
`{"error":"no Stub matched"}`, and a [Near miss](#when-no-stub-matches)
that names the closest Stub. A client that reads the vendor's error body
needs a Stub that answers every other path of the Mock with it. That is an
ordinary Stub with no conditions, not the
[Default Mock](#hosts-and-the-default-mock), which answers the Hosts that
no Mock lists. Leave out its `priority` and declare it after the Mock's
other Stubs, so that it is tried last: a Stub without a priority is tried
after every Stub with one, and among those in declaration order
([Which Stub answers](#which-stub-answers)).

```yaml
mocks:
  - name: openai
stubs:
  - id: chat
    mock: openai
    request: { method: POST, path: /v1/chat/completions }
    response:
      status: 200
      llm:
        api: openai-chat
        text: Hello! How can I assist you today?
  - id: other-paths
    mock: openai
    response:
      status: 404
      template: true
      headers: { x-request-id: req_eTuAaXsuWSSRENWrCE3JNEi7 }
      json:
        error:
          message: Invalid URL (${method} ${path})
          type: invalid_request_error
          param: null
          code: null
```

openai-python raises `NotFoundError` for it, and does not retry it. For
Anthropic, the body is
`{"type":"error","error":{"type":"not_found_error","message":"Not found"},"request_id":"req_…"}`,
with the same id in `request-id`.

With such a Stub, every request of the Mock matches. None has a Near miss,
and `GET /v1/journal/unmatched` lists none of them. The Journal names the
Stub that answered each request, so a test finds stray calls by that
Stub's id.

### Prompts in the Journal

An LLM request carries the whole conversation, and often the tools'
schemas, so its body often passes 4 KiB. The
[Journal](../README.md#the-journal) keeps the first 4 KiB of each body by
default, and the entry's body then says `truncated: true`. A test that
reads prompts from the Journal raises `--journal-body-limit`
(`SMOCK_JOURNAL_BODY_LIMIT`), such as `--journal-body-limit 1048576`. Each
entry then takes more of the Journal's byte bound. Conditions and
templates always read the whole body.

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
- In `llm`, the text, each chunk, `id`, `model` and each tool call's
  `name`, `id` and `arguments` are templates, as
  [Templates in LLM replies](#templates-in-llm-replies) says.
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
when `a` is present, otherwise `b`. There are no arithmetic operators, no
string operators and no user-defined functions: [helpers](#helpers) do that
work, such as `add(a, b)`.
The words `for`, `if`, `else`, `end`, `each` and `params` are reserved.

| Name | Value |
|---|---|
| `method` | The request method, such as `GET`. |
| `path` | The percent-decoded path without the query, as conditions compare it. |
| `path[n]` | Segment `n` of that path, counted from 0 after the leading `/`: for `/users/42`, `path[0]` is `users` and `path[1]` is `42`. |
| `query.NAME` | The first decoded value of the query parameter. |
| `header.NAME` | The first value of the header, its name compared case-insensitively; each field line is one value. |
| `cookie.NAME` | The first value of the cookie, read from every `Cookie` field as [cookie conditions](#cookies) read it. |
| `body` | The body parsed as JSON. `body.a.b`, `body.items[0]` and `body['odd.key']` walk into it. |
| `bodyText` | The body as text; bytes that are not UTF-8 become U+FFFD. |
| `env.NAME` | The value of an environment variable that `--template-env` lists, as a string; see [Environment variables](#environment-variables). |
| `vars.NAME` | The [Variable](#variables) `NAME` of the request's Mock and Session, with its own type. `vars.cart.items[0]` walks into it. |
| `data.NAME` | The [Data bucket](#data-buckets) `NAME` of the Stub's Mock, with its own type. `data.orders[0].id` walks into it. |
| `loop.index` | The position in the innermost `$each`, from 0. |
| a loop variable | The current element of the `$each` that names it with `as`. |

A name in a reference is ASCII letters, digits, `_` and `-`; write any other
name as `['…']`, such as `query['page size']`.

`cookie.NAME` reads cookies exactly as a cookie condition does, so what a
condition matched is what a template inserts:

- Every `Cookie` field counts. Each is split on `;`, and each part is
  trimmed of spaces and tabs.
- The first `=` of a part separates the name from the value. A part
  without `=` holds no cookie.
- Names are compared exactly, case and all.
- Values stay as sent: quotes are kept, and nothing is percent-decoded. So
  `Cookie: session="s1"` gives `"s1"` with its quotes.
- An absent cookie is missing, so `??` gives a fallback, as in
  `${cookie.session ?? null}`.

```yaml
json:
  session: ${cookie.session ?? null}
  themes: { $each: cookie.theme, as: t, do: "${t}" }
```

A request with `Cookie: theme=dark; session="s1"` and a second line
`Cookie: theme=light` gets `{"session":"\"s1\"","themes":["dark","light"]}`.

A helper call can be followed by steps into what it gives, as `body` can:
`.name`, `[n]` and `['name']`. `${range(1, 3)[1]}` gives `2`. A step into
what is not an object or an array, or past its end, gives a missing value,
so `??` applies: `${range(1, 3)[5] ?? 'none'}` gives `none`.

### Structured templates

In `json`:

- A string that is exactly one `${expr}` gives the value with its own type:
  a number stays a number and an object stays an object. Any other string
  gives a string, each value written as text.
- `{ "$each": expr, "as": name, "do": template }` gives an array, one
  element per item. It walks an array (from `body` or a loop variable),
  every value of a query parameter, a header or a cookie (none when it is
  absent), or `range(a, b)`. The name in `as` cannot be a request field
  (`method`, `path`, `query`, `header`, `cookie`, `body` or `bodyText`),
  `env`, `vars`, `data`, `loop` or a reserved word.
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

Helpers come in families. Each family says how many arguments its helpers
take, and which of them must be literals.

**Fake data.** Every argument is a literal.

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

**Time.** The argument, if any, is a literal.

| Helper | Arguments | Output |
|---|---|---|
| `now()`, `now(s)` | `s`: an integer literal, seconds, may be negative | The time of the request plus `s` seconds, RFC 3339 in UTC with milliseconds. |
| `now(format)` | `format`: a string literal, a format as for **Dates** below | The time of the request, in UTC, written in `format`. |
| `nowMillis()`, `nowMillis(s)` | as for `now` | The same instant in milliseconds since the Unix epoch. |

**Conversions.** Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `number(x)` | a string or a number | `x` as a number. |
| `range(a, b)` | integers from -(2^53 - 1) to 2^53 - 1 | The integers from `a` to `b`, for `$each`; none when `a > b`. |
| `json(x)` | any value | Text templates only: `x` written as JSON. |
| `raw(x)` | a string, number, boolean or null | Text templates only: `x` without escaping. |

A bound of `range` can be any expression that gives an integer, such as
`len(body.items)`; a string is not one, so write `number(query.n)` for a
bound from the query. A bound that is not an integer in range is an error
when the template is rendered. Literal bounds, and the limit of 1000
values when both bounds are literals, are checked when the files are
loaded.

**Strings.** Each argument may be any expression. Lengths count Unicode
code points, so an emoji or a Japanese character counts as one.

| Helper | Arguments | Output |
|---|---|---|
| `len(x)` | text, or an array | The length of the text in code points, or the number of elements of the array. |
| `concat(a, b, …)` | 2 to 100 texts | The texts joined. |
| `padStart(s, length, pad)`, `padEnd(s, length, pad)` | text; an integer; text, by default one space | `s` padded at its start or end to `length` code points, the pad repeated and cut to fit, as JavaScript does. A text that long already, or an empty pad, is unchanged. |
| `substr(s, from, length)` | text; an integer; an integer, by default the rest | The code points of `s` from `from`, `length` of them. A negative `from` counts from the end. Positions out of range clamp, so `substr('abc', 5)` and a negative `length` give an empty text. |
| `indexOf(s, search, from)` | text; text; an integer, by default 0 | The code-point index of the first `search` in `s` at or after `from`, or -1 when there is none. A negative `from` counts as 0, and a `from` past the end gives -1. |
| `includes(s, search)` | text; text | `true` when `search` occurs in `s`, otherwise `false`. An empty search occurs in every text. |
| `replace(s, search, replacement)`, `replaceAll(s, search, replacement)` | text | `s` with the first, or every, occurrence of `search` replaced, found from the start without overlap. Both are literal text: `$&` and `$1` are written as they are. An empty search leaves `s` unchanged. |
| `split(s, separator)` | text; text | An array of the texts between the occurrences of `separator`, found from the start. An empty separator splits into code points. An empty `s` gives `[""]`, whatever the separator. |
| `join(array, separator)` | an array; text | The elements written as text, with `separator` between them. `null` is written as an empty text. An object or an array as an element is an error. |
| `uppercase(s)`, `lowercase(s)` | text | `s` with each code point mapped to its upper or lower case, one code point to one. |
| `trim(s)` | text | `s` without White_Space at either end. |

```yaml
response:
  status: 200
  template: true
  json:
    code: ${padStart(query.n, 6, '0')}
    name: ${concat(body.first, ' ', body.last)}
    lines: { $each: "range(1, len(body.items))", as: i, do: "${i}" }
```

`?n=42` with the body `{"first":"Ann","last":"Lee","items":["a","b"]}` gets
`{"code":"000042","name":"Ann Lee","lines":[1,2]}`.

The array that `split` gives can be a `$each` source, the whole value of a
`${…}` in a structured template, or read with a step. In text, write it
with `json(…)`. `join` turns an array back into text:

```yaml
response:
  status: 200
  template: true
  json:
    ids: { $each: "split(query.ids, ',')", as: id, do: "${id}" }
    first: ${split(query.ids, ',')[0]}
    tags: ${join(body.tags, '|')}
    short: ${substr(body.name, 0, 3)}
```

`?ids=a,b,c` with the body `{"tags":["x",null,1],"name":"東京タワー"}` gets
`{"ids":["a","b","c"],"first":"a","tags":"x||1","short":"東京タ"}`.

`uppercase`, `lowercase` and `trim` read the data of Unicode 18.0.0, which
is built into smock. That data does not change within format version 1, so
they give the same output on every machine and in every release.

- Case mapping is the simple one in the Unicode Character Database: each
  code point maps to one code point, whatever the locale. There is no
  special casing, so `ß`, whose upper case is two letters, stays `ß`, and
  `İ` becomes `i`. Characters without case, such as digits, Japanese text
  or emoji, stay as they are.
- `trim` removes the code points with the Unicode property White_Space:
  tab, line feed, the other ASCII spaces and line breaks, and those beyond
  ASCII, such as U+00A0 NO-BREAK SPACE and U+3000 IDEOGRAPHIC SPACE. U+200B
  ZERO WIDTH SPACE and U+FEFF ZERO WIDTH NO-BREAK SPACE are not White_Space,
  so they stay.

```yaml
response:
  status: 200
  template: true
  json:
    code: ${uppercase(body.code)}
    name: ${trim(query.name)}
```

The body `{"code":"straße-ç"}` with `?name=%E3%80%80Ann%20` (an ideographic
space before the name, a space after it) gets
`{"code":"STRAßE-Ç","name":"Ann"}`.

**Arrays.** Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `find(array, member, value)` | an array; a string; a string, a number, a boolean or null | The first element of `array` that is an object whose member `member` meets `value`. |
| `last(array)` | an array | The last element of `array`, with its own type. |

`value` is taken as text: a string as it is, a number as smock writes it
in `json`, and `true`, `false` and `null` as those words. Unlike the
string helpers, `find` takes `null`. A member meets the value when:

- it is a string equal to that text;
- it is a number, and the text is a JSON number of equal value, compared
  as [`json` conditions](#how-a-stub-matches-a-request) compare numbers:
  `12.50` meets `12.5`, and integers beyond 2^53 are compared exactly;
- it is `true`, `false` or `null`, and the text is that word.

Objects, arrays and absent members never meet the value. So
`find(body.orders, 'id', 1004)`, `find(body.orders, 'id', '1004')` and,
for `/orders/1004`, `find(body.orders, 'id', path[1])` all find the order
whose `id` is `1004` or `"1004"`. When no element meets the value, the
call is missing, so `??` gives a fallback. `find` gives an element and
builds nothing, so the 1 MiB bound on a helper's result does not apply;
the bound on the rendered body still does.

```yaml
response:
  status: 200
  template: true
  json: "${find(body.items, 'sku', query.sku) ?? 'no such item'}"
```

`?sku=42` with the body `{"items":[{"sku":7,"qty":3},{"sku":42,"qty":1}]}`
gets `{"sku":42,"qty":1}`, and `?sku=5` gets `"no such item"`.

`last` gives the last element of an array, and steps can follow it, as
they follow any call. An empty array gives a missing value, so `??` gives
a fallback. A value that is not an array is an error. Like `find`, `last`
gives an element and builds nothing.

```yaml
response:
  status: 200
  template: true
  json:
    answer: It is ${last(body.messages).content ?? 'unknown'} in Paris.
```

The body
`{"messages":[{"role":"user","content":"Weather?"},{"role":"tool","content":"18 °C"}]}`
gets `{"answer":"It is 18 °C in Paris."}`, and `{"messages":[]}` gets
`{"answer":"It is unknown in Paris."}`.

A response reads the Data buckets after its own Stub's writes ([When data
is written](#when-data-is-written)). So `last` answers the item that the
Stub's `append` just added to a keyed bucket, its [new key](#new-keys)
included:

```yaml
- id: add-order
  mock: shop
  request: { method: POST, path: /api/v1/orders }
  dataWrites:
    - { op: append, bucket: orders, value: "${body}" }
  response:
    status: 201
    template: true
    headers: { Location: "/api/v1/orders/${last(data.orders).id}" }
    json: "${last(data.orders)}"
```

With the orders 1001 to 1003 keyed by `id`, `POST /api/v1/orders` with
the body `{"status":"new"}` gets `Location: /api/v1/orders/1004` and
`{"status":"new","id":1004}`. The next one in the same Session gets 1005.

**Encodings.** Each argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `base64(s)` | text | The UTF-8 bytes of `s` in base64, with `=` padding. |
| `base64url(s)` | text | The same in base64url, the URL-safe alphabet, without padding. |
| `base64Decode(s)`, `base64urlDecode(s)` | text | The bytes that `s` encodes in base64, or in base64url, as text. |
| `urlEncode(s)` | text | The UTF-8 bytes of `s` percent-encoded, as RFC 3986 says, with upper-case hex digits. Only `A-Z a-z 0-9 - . _ ~` stay as they are, so a space becomes `%20`. |
| `urlDecode(s)` | text | `s` with each percent-escape decoded. `+` stays `+`. |

The decoders are strict, so a malformed input is an error, not a partial
result:

- `base64Decode` takes only the standard alphabet, `A-Z a-z 0-9 + /`, and
  `base64urlDecode` only the URL-safe one, `A-Z a-z 0-9 - _`. Any other
  character, whitespace included, is an error.
- Padding may be left out. Padding that is given must be complete and at
  the end: `Zg==` and `Zg` both give `f`, but `Zg=`, `Zg===` and `Zg==Zg==`
  are errors. Bits after the last byte are ignored.
- In `urlDecode`, a `%` that two hex digits, in either case, do not follow
  is an error.
- Decoded bytes that are not UTF-8 become U+FFFD, as in `bodyText`.

```yaml
response:
  status: 200
  template: true
  headers:
    Location: /search?q=${urlEncode(query.q)}
  json:
    token: ${base64url(query.token)}
    basic: ${base64(concat(body.user, ':', body.password))}
    text: ${base64Decode(body.data)}
```

`?q=a%20b%26c&token=a%2Bb` with the body
`{"user":"ann","password":"pw","data":"aGk="}` gets
`Location: /search?q=a%20b%26c` and
`{"token":"YSti","basic":"YW5uOnB3","text":"hi"}`.

**JWTs.** The argument may be any expression.

| Helper | Arguments | Output |
|---|---|---|
| `jwtPayload(token)`, `jwtHeader(token)` | text | The payload, or the header, of the JWT `token`, as a JSON object. Read a claim with a step, such as `jwtPayload(header.authorization).sub`. |

- smock only decodes the token. It never checks the signature, the `alg`
  or a claim such as `exp`, so it reads an unsigned or forged token like
  any other. Never rely on a mock to verify tokens.
- A leading `Bearer`, in any case, is removed when spaces or tabs follow
  it, and they go with it. So `header.authorization` can be passed as it
  is.
- A token is a JWS in compact form: three base64url parts separated by
  `.`, padding optional, the first two each the UTF-8 of a JSON object.
  The third part, the signature, may be empty.
- Anything else is missing, so `??` gives a fallback: no token, a
  malformed one, wrong padding (an error in `base64urlDecode`), a JWE of
  five parts, or a value that is not text.
- A member name that repeats keeps its last value, as RFC 7519 allows for
  claims.

```yaml
response:
  status: 200
  template: true
  json:
    user: ${jwtPayload(header.authorization).sub ?? 'anonymous'}
    alg: ${jwtHeader(header.authorization).alg ?? null}
```

With
`Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1LTQyIn0.c2ln`,
whose payload is `{"sub":"u-42"}`, the body is
`{"user":"u-42","alg":"HS256"}`. Without the header, or with a malformed
token, it is `{"user":"anonymous","alg":null}`.

**Dates.** The date may be any expression. The format, the offset and the
duration are string literals.

| Helper | Arguments | Output |
|---|---|---|
| `dateFormat(date, format, offset)` | a date; a format; an offset, by default `Z` | `date` at `offset`, written in `format`. |
| `dateTimeShift(date, duration)` | a date; a duration | `date` shifted by `duration`, RFC 3339 in UTC with milliseconds, as `now()` writes it. |

- A date is an RFC 3339 date-time with an offset, such as
  `2026-01-31T19:00:00+09:00`; a date `YYYY-MM-DD`, read as midnight in
  UTC; or a number without a fraction, read as milliseconds since the Unix
  epoch, such as `nowMillis()` gives. A date is an instant: the offset it
  was written with is not kept.
- Anything else is missing, so `??` gives a fallback: a date-time without
  an offset, a date that does not exist, such as `2026-02-30`, a number
  with a fraction, or a string of digits. Write `number(query.ts)` to read
  milliseconds from the query. A literal that is not a date is an error
  when the files are loaded.
- An offset is `Z`, or `+HH:MM` or `-HH:MM` with `HH` up to 23 and `MM` up
  to 59, as RFC 3339 writes one. There are no time-zone names and no local
  time.
- A duration is an ISO 8601 duration with an optional sign, such as `P1M`,
  `-P2D`, `PT90M` or `P1Y2M3DT4H5M6S`: `P`, then years `Y`, months `M` and
  days `D`, then `T`, hours `H`, minutes `M` and seconds `S`. Each amount
  is optional, a whole number of at most 9 digits, in that order. Weeks
  (`W`) and fractions are errors when the files are loaded.
- A shift applies years and months first, on the UTC calendar. When the
  day does not exist in the month it reaches, it is that month's last day,
  so January 31 plus `P1M` is February 28, or 29 in a leap year. Then it
  applies days, then hours, minutes and seconds.
- A date, or a time that a date helper writes, outside the years 0 to 9999
  is an error when the template is rendered. `dateFormat` checks the date
  at its offset too.

A format uses date-fns tokens, as Mockoon's are, so most Mockoon formats
carry over:

| Token | Writes | At 2026-03-05T14:07:08.045Z |
|---|---|---|
| `yyyy`, `yy` | The year in four digits, or its last two. | `2026`, `26` |
| `M`, `MM`, `MMM`, `MMMM` | The month: its number, with a leading zero, or its short or full name. | `3`, `03`, `Mar`, `March` |
| `d`, `dd` | The day of the month. | `5`, `05` |
| `EEE`, `EEEE` | The day of the week, short or full. | `Thu`, `Thursday` |
| `H`, `HH` | The hour from 0 to 23. | `14`, `14` |
| `h`, `hh`, `a` | The hour from 1 to 12, and `AM` or `PM`. | `2`, `02`, `PM` |
| `m`, `mm`, `s`, `ss` | Minutes and seconds. | `7`, `07`, `8`, `08` |
| `S`, `SS`, `SSS` | Tenths, hundredths or milliseconds of the second. | `0`, `04`, `045` |
| `X`, `XX`, `XXX` | The offset: `Z` when it is zero, otherwise `+09` (`+0530` when the minutes are not zero), `+0900` or `+09:00`. | `Z`, `Z`, `Z` |
| `x`, `xx`, `xxx` | The same, with `+00`, `+0000` or `+00:00` when it is zero. | `+00`, `+0000`, `+00:00` |
| `t`, `T` | Seconds, or milliseconds, since the Unix epoch. | `1772719628`, `1772719628045` |
| `'…'`, `''` | The text between the quotes as it is, and one quote. | |

- Names are in English only, so no output depends on a locale.
- Characters that are not ASCII letters are written as they are. Quote
  letters to write them: unquoted, `T` writes milliseconds and `at` is `a`
  then `t`, so write `'T'` and `'at'`.
- `YYYY`, `YY` and `Y` (the week-numbering year) and `D` and `DD` (the day
  of the year) are errors when the files are loaded, so they never write a
  wrong date at the turn of a year: write `yyyy` and `dd`. So is any other
  unquoted ASCII letter, a run of a letter of a length the table does not
  list, such as `yyy`, and a quote that is not closed.
- `yyyy` and `yy` write the calendar year, so the year 0 is `0000` and
  `00`, as smock writes it in RFC 3339 times. date-fns writes the year of
  the era there instead: `0001`, for 1 BC.

```yaml
response:
  status: 200
  template: true
  json:
    today: ${now('yyyy-MM-dd')}
    due: ${dateFormat(dateTimeShift(now(), 'P1M'), 'yyyy-MM-dd', '+09:00')}
    issued: ${dateFormat(query.issued ?? now(), "EEE, d MMM yyyy 'at' HH:mm XXX", '+09:00')}
```

A request received at 2026-01-31T10:00:00Z with
`?issued=2026-03-05T14:07:08Z` gets
`{"today":"2026-01-31","due":"2026-02-28","issued":"Thu, 5 Mar 2026 at 23:07 +09:00"}`.

The string helpers, and the families added after them, read their
arguments by one set of rules:

- A text argument is a string. A number or a boolean is taken as its text,
  a number written as in `json`. Null, an object or an array is an error.
- A numeric argument is a number, or a string that is a JSON number, as
  `number(x)` reads it. An integer argument is a numeric one without a
  fraction, so `6`, `6.0` and `'6'` are all 6. An integer too large to
  hold, such as `1e300`, is out of range, so as a position it clamps as
  other positions do.
- A value of the wrong kind from the request is an error when the template
  is rendered; the JWT helpers, and the date helpers for a date, give a
  missing value instead. A literal of the wrong kind, such as
  `padStart(query.n, 'six')` or `concat(null, 'a')`, is an error when the
  files are loaded, and so is a literal alternative of a fallback, such as
  the `true` of `padStart(query.n, query.width ?? true)`.
- A helper's result may take at most 1 MiB of UTF-8, an array or an object
  counted as its compact JSON. A larger one is an error, found before it is
  built. This is on top of the 1 MiB bound on a rendered body.

**Arithmetic.** Each argument may be any expression, except the `places`
of `toFixed`. Each helper takes a fixed number of arguments, so nest calls
for more operands, as in `add(add(a, b), c)`. The arithmetic is exact in
decimal and uses integers only, so `add(0.1, 0.2)` is `0.3`, and every
result is the same on native and on wasm-gc.

| Helper | Arguments | Output |
|---|---|---|
| `add(a, b)`, `subtract(a, b)`, `multiply(a, b)` | numbers | `a + b`, `a - b` or `a × b`, exact. |
| `divide(a, b)` | numbers; `b` not 0 | `a ÷ b`, rounded half to even at 10 decimal places: `divide(10, 3)` is `3.3333333333`, and `divide(1, 2048)`, which is 0.00048828125, is `0.0004882812`. |
| `modulo(a, b)` | numbers; `b` not 0 | The remainder of `a ÷ b` truncated toward zero, so it has the sign of `a`, as JavaScript's `%` does: `modulo(-7, 3)` is `-1`. |
| `ceil(x)`, `floor(x)` | a number | The nearest integer toward +∞, or toward −∞. |
| `round(x)` | a number | The nearest integer, half away from zero: `round(2.5)` is `3` and `round(-2.5)` is `-3`. |
| `toFixed(x, places)` | a number; an integer literal from 0 to 18 | `x` rounded half away from zero to `places` decimals, and written with exactly that many, as `fake.decimal` writes its numbers: `toFixed(1.005, 2)` is `1.01`, and `toFixed(19.99, 3)` is `19.990`. |
| `parseInt(x)` | a number | The integer part of `x`, truncated toward zero: `parseInt(-12.7)` is `-12`. |

```yaml
response:
  status: 200
  template: true
  json:
    total: ${multiply(body.price, body.qty)}
    next: ${add(query.page ?? 1, 1)}
    third: ${divide(10, 3)}
    price: ${toFixed(body.price, 3)}
```

`?page=4` with the body `{"price":19.99,"qty":3}` gets
`{"total":59.97,"next":5,"third":3.3333333333,"price":19.990}`.

- A numeric argument is read as a decimal. A number is taken as smock
  writes it in `json`: the text it kept, such as the digits of an integer
  beyond 2^53 or the output of `fake.decimal`, otherwise the shortest form
  that reads back as the same 64-bit float. So `19.99` is 19.99, not the
  float nearest to it. A string that is a JSON number is taken as its own
  text, so `add('0.10', 1)` is `1.1`.
- A number literal in an argument is taken as written, with every digit,
  even those a 64-bit float would lose: `add(0.123456789012345678, 0)` is
  `0.123456789012345678`, and `add(0.12345678901234567891, 0)`, with 20
  digits after the point, is an error when the files are loaded. How a
  literal is written anywhere else does not change:
  `${0.123456789012345678}` alone still writes `0.12345678901234568`, as
  `json` would.
- Numbers have at most 18 digits before the point and 18 after. Zeros
  before the first digit that is not 0, and after the last one, do not
  count, so `'1.000000000000000000000'` is 1. An argument beyond the bounds
  is an error, found when the files are loaded for a literal. A result
  beyond them is an error too: `multiply` never rounds, so
  `multiply('0.000000001', '0.0000000001')` is an error, not 0. Within the
  bounds, integers keep every digit: there is no rounding at 2^53.
- A result is a number, written as a plain decimal with no exponent and no
  trailing zeros: `add(1.50, 1)` is `2.5`, `divide(1, 10000000)` is
  `0.0000001`, and zero is `0`, never `-0`. `toFixed` keeps exactly
  `places` decimals instead, and writes `toFixed(-0.001, 2)` as `0.00`.
- Other helpers and conditions take a result as a number, so
  `padStart(s, add(n, 1))`, `range(1, add(n, 1))` and
  `$if: add(a, b) == 3` all work. Where an integer is taken, a result is
  the decimal it writes, so one with a fraction is not an integer, however
  small: `substr(s, add(1, '0.000000000000000001'))` is an error.
- A zero divisor of `divide` or `modulo`, even a literal 0, is an error
  when the template is rendered.

None of these helpers draws from the random source.

The word and name lists are part of format version 1. A matched request
takes exactly one 64-bit output from its Stub's random source (its own
generator with `fault.seed`, otherwise the process generator, see
[Seeds](#seeds)), whatever its template draws: the Fault decisions draw
from a generator seeded with it, the pick among
[`responses`](#several-responses) from another one seeded with it XOR a
fixed constant, and the helpers from a third one seeded with it XOR another
constant, in render order (header values in the order
written, an array's values in order, then the body, members and loop
iterations in order, or the events in order, each event's `event`, `id`,
then `data` or `json`). So a seeded Stub repeats its helper output on
every run, on native and on wasm-gc alike, and adding fake data never
changes its Faults or its picks.

`now()`, `now(format)` and `nowMillis()` read the time smock received the
request at, never the clock while rendering; in an event, they add the
delays of the events up to and including it:

```yaml
response:
  status: 200
  template: true
  headers: { Cache-Control: no-cache }
  events:
    - { event: price, id: "1", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, event: price, id: "2", json: { symbol: "${query.symbol}", price: "${fake.decimal(90, 110, 2)}", at: "${now()}" } }
    - { delay: 500, data: "[DONE]" }
fault: { seed: 7 }
```

The last event is `data: [DONE]` alone, the frame that ends an OpenAI
Chat Completions stream, which has no `event:` line. To stand in for an
LLM API, an [LLM response](#llm-responses) writes the reply in the API's
wire form, so no event needs writing by hand.

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
absent). A call with a missing argument is missing too, and so are a JWT
helper's call on what is not a token and a `find` that finds no element.

Type errors are errors as well: a loop over what is not an array,
`number(x)` of text that is not a JSON number, a `range` bound that is not
an integer, a helper argument of the wrong kind, an object or an array in
text, a zero divisor, and a bound exceeded. `range` gives at most 1000
values, one response runs at most 10,000 loop iterations in all, a
helper's result takes at most 1 MiB, an arithmetic helper's numbers have
at most 18 digits before the point and 18 after, and a rendered body, or
all the events of a response together, takes at most 1 MiB. So does an
[LLM reply](#the-size-bound) once encoded. Bounds that literals give are
checked when the files are loaded.

When a template cannot be rendered for a request, the client gets status
500, `Content-Type: application/json` and
`{"error":"template failed","stub":"<id>","at":"<JSON Pointer within the Stub>","message":"<what>"}`,
such as `"at":"/response/json/customer","message":"body.customer.name is missing"`.
A delay Fault still applies first, and a connection Fault still replaces
the response. A stream is rendered whole before its head is sent, so a
failed event also gives this 500 and no stream. The Journal entry records
the 500 and `templateError`, and no log line is written.

### Environment variables

A template can read an environment variable only when it is listed with
`--template-env` (`SMOCK_TEMPLATE_ENV`), names separated by commas.
`env.NAME` gives its value as a string.

```yaml
response:
  status: 200
  template: true
  json:
    region: ${env.REGION ?? 'local'}
```

With `smock serve --template-env REGION` and `REGION=eu-west-1`, the
response is `{"region":"eu-west-1"}`, and with `REGION` unset,
`{"region":"local"}`. Without `--template-env REGION`, the file does not
load.

- `env` takes exactly one name: `env.REGION` or `env['REGION']`. `${env}`
  alone and `env.REGION.x` are errors when loading. A loop variable cannot
  be named `env`.
- A name that is not listed is an error when loading, so `smock check`
  catches a typo.
- A listed variable that is unset is missing, so `??` gives a fallback. A
  variable set to the empty string is present.
- A listed name is ASCII letters, digits and `_`, starting with a letter or
  `_`. A name that starts with `SMOCK_` cannot be listed, so smock's own
  variables, such as `SMOCK_ADMIN_TOKEN`, never reach a template. Either
  mistake is a usage error: smock exits with status 2.
- The values are read once, at startup. Every load uses them: the first
  one, each reload and each Ephemeral Stub that is added. A reload does
  not read them again, so restart smock to change a value.
- `smock check` and `smock render` take the same flag and variable, and
  read the values from their own environment, so that they accept the same
  templates as `smock serve`.
- The values are not part of the
  [definition set digest](#reloading).

A listed value reaches only what a template that reads it produces: a
response, a rendering, a [Variable](#variables) it writes (which the
Admin API lists), or a template error message that quotes it, such as
`number(): "eighty" is not a JSON number`. Such a message goes into the 500
of the failed template and into the Journal entry's `templateError`.
smock writes no value in its logs or in the Admin API status, and the
Journal holds one only inside such a message. So list only values that may
be shown to whoever can send requests to smock or read its Journal.

### Variables

A *Variable* is a named JSON value that smock keeps per Mock and per
Session. A Stub's `variables` write Variables when the Stub matches, and
templates read them as `vars.NAME`. So a POST can store what a later GET
returns:

```yaml
- id: login
  mock: shop
  request: { method: POST, path: /login }
  variables:
    user: ${body.user}
    previous: ${vars.user ?? null}
  response:
    status: 200
    template: true
    json: { user: "${vars.user}", previous: "${vars.previous}" }
- id: whoami
  mock: shop
  request: { method: GET, path: /me }
  response:
    status: 200
    template: true
    json: { user: "${vars.user ?? null}" }
```

In one Session, `POST /login` with `{"user":"ann"}` gets
`{"user":"ann","previous":null}`, and `GET /me` then gets
`{"user":"ann"}`. Another Session still gets `{"user":null}`.

- `variables` maps the name of each Variable to its value. It sits beside
  `response` or `responses`, so a Stub has one set of writes, whichever
  response is picked.
- A name is 1 to 128 ASCII letters, digits, `_` and `-`.
- A value is any JSON. It is always a [structured
  template](#structured-templates), whether or not a response has
  `template: true`: `${…}` inserts a value, and `$${` writes `${`. As at
  the root of `json`, a `$if` at its root needs `else`.
- Writing `null` stores null. It does not delete the Variable.
- Variables are kept per Mock and per Session, like Scenario state.
  Requests without a Session share one space per Mock. Each replica keeps
  its own, and they are lost on restart. A reset clears them, and a reload
  keeps them ([Resets and reloads](#resets-and-reloads)). One byte bound
  holds all of them ([The state bound](#the-state-bound)).
- An [Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs) takes
  `variables` too, and writes the Variables of its Session.
- Through the Admin API, a test lists, sets and deletes the Variables of
  its own Session ([Through the Admin API](#through-the-admin-api)).

#### When Variables are written

The values are written at the match decision, as a Scenario moves, in this
order:

1. The Scenario moves.
2. The request takes its one random draw (see [Helpers](#helpers)).
3. Every value is rendered, in the order written, against the Variables as
   they were before this request. So
   `count: ${concat(vars.count ?? '', 'x')}` adds an `x` with each
   request, and two values that read each other see the old values. The
   values draw their helper output first, and the response's helpers draw
   on from there, so [`fault.seed` and `--seed`](#seeds) replay them.
4. All the values are written at once, if they fit within [the state
   bound](#the-state-bound).
5. The response is picked, as for any Stub with
   [`responses`](#several-responses), then rendered. It sees the new
   values.

A Stub with [`dataWrites`](#writing-buckets-datawrites) renders the value
of each write after the values of its Variables, against the same state
from before the request, and stores the writes with the Variables, all at
once or not at all ([When data is
written](#when-data-is-written)).

A value that fails to render writes none of the Stub's Variables. The
request gets the [template failure](#missing-values-and-render-errors),
500 with an `at` under `/variables/NAME`, such as
`"at":"/variables/user","message":"body.user is missing"`. No response is
picked. The Scenario move stands, and the delay and the connection Fault
apply as for any template failure. Writes that would pass the state bound
are refused the same way, with 507.

Each value is bounded as a rendered body is: at most 1 MiB of compact JSON,
and at most 10,000 loop iterations. Past either is a render error.

Once written, a value stays: a delay, a connection Fault or a response
that fails to render does not undo the write, and the next request sees
it. Nothing expires a Variable, but the state bound limits what all of
them take.

#### Reading Variables

- `vars.NAME` gives the value with its own type, and steps go into it:
  `${vars.cart.items[0].sku}`. It works in every template, the values of
  `variables` included.
- An unset Variable is missing, so `??` gives a fallback:
  `${vars.count ?? 0}`. A Variable set to `null` is present.
- `vars` takes the name of a Variable first: `${vars}` alone and
  `${vars[0]}` are errors when loading. A loop variable cannot be named
  `vars`.
- A name that no Stub in the files writes is not an error, since an
  Ephemeral Stub or the Admin API can write it.
- `smock render` and the Admin render operation read Variables from the
  sample's `vars`, never the live ones, and show the values a Stub would
  write without writing them (see [Rendering a
  template](#rendering-a-template)).

Each [Journal](../README.md#the-journal) entry records the names of the
Variables the request wrote, in the order written, as `variablesWritten`.
It is empty for a Stub without `variables`, for a request that no Stub
matched, when a value failed to render, and when the state bound refused
the writes.

#### Through the Admin API

A test can arrange and inspect the Variables of its own Session through
the Admin API. Each operation names its Session as other Admin API calls
do, and one without a Session works on the Mock's no-Session space:

- `GET /v1/mocks/{mock}/variables` lists them by name, in byte-wise order,
  with their values:
  `{"variables":{"previous":null,"user":"ann"},"warnings":[]}`.
- `PUT /v1/mocks/{mock}/variables/{name}` sets one. The body is the value
  itself, any JSON: `"ann"`, `42` or `{"items":[]}`. It replaces the value
  the Variable had, and `null` stores null. The reply is
  `{"name":"user","value":"ann","warnings":[]}`.
- `DELETE /v1/mocks/{mock}/variables/{name}` deletes one, so `vars.NAME` is
  missing again. The reply is `{"name":"user","warnings":[]}`.

So, for the [`whoami` Stub above](#variables), a test that sends
`PUT /v1/mocks/shop/variables/user` with the body `"ann"` before it calls
`GET /me` gets `{"user":"ann"}`, and can list the Variables afterwards to
check what its requests wrote.

- A Mock that does not exist gets 404 `unknown_mock`.
- A name that is not 1 to 128 ASCII letters, digits, `_` and `-` gets 400
  `invalid_request`, and a set without a body too. A body that is not JSON
  gets 400 `malformed_json`, as for other operations.
- A value that takes more than 1 MiB as compact JSON gets 400
  `invalid_request` and writes nothing, so a set is bounded as each value
  of a Stub's `variables` is.
- A set keeps a number's value, not its text: smock writes it as `json`
  does, so `19.990` is stored as `19.99` and `1e3` as `1000`, and only an
  integer beyond 2^53 keeps its digits. A Stub's `variables` keep the text
  a value renders with instead, such as `19.990` from `toFixed(x, 3)`. To
  keep a number's text through a set, set it as a string, such as
  `"19.990"`, which the arithmetic helpers take as that number.
- A delete of a Variable the Session has not set gets 404
  `unknown_variable`. Another Session's Variables are never listed, set or
  deleted.
- A set counts against [the state bound](#the-state-bound) as a Stub's
  writes do. A delete gives back the bytes the Variable counted.
- Each set and delete writes a log entry that names the Mock, the Session
  and the Variable, but not the value:

  ```json
  {"time":"2026-10-21T09:00:00.000Z","level":"info","msg":"Variable set","mock":"shop","session":"test-a","variable":"user"}
  ```

#### Resets and reloads

A [reset](../README.md#sessions-and-ephemeral-stubs) clears the Variables
in its scope, so that a test starts clean:

- `{"scope":"session"}` clears the calling Session's Variables in every
  Mock, or those of requests without a Session when the call carries none;
- `{"scope":"mock","mock":"shop"}` clears every Session's Variables of
  `shop`, those of requests without a Session included;
- `{"scope":"all"}` clears every Variable.

The reset answers how many Variables it cleared, in `removed.variables`,
and its log entry says the same. A cleared Variable is unset, so
`vars.NAME` is missing again.

A [reload](#reloading) that swaps in new files keeps every Variable, even
one that no Stub writes any more, except those of a Mock the new files no
longer declare, which are dropped. A reload that fails, or finds the files
unchanged, keeps them all. So editing the files does not wipe the state of
a test in progress.

#### The state bound

One byte bound holds the per-Session state of the whole process, across
every Mock and Session, so that Variables and the copies of [Data
buckets](#data-buckets) cannot exhaust a small Pod.

- `--state-max-bytes` or `SMOCK_STATE_MAX_BYTES` sets it, in bytes, from 1
  to 1073741824 (1 GiB), as `--journal-max-bytes` takes.
- Without either, it follows smock's memory limit, as the Journal's byte
  bound does ([ADR
  0004](adr/0004-journal-byte-bound-follows-the-memory-limit.md)): an
  eighth of the memory limit of smock's cgroup (cgroup v2 `memory.max`),
  rounded down, at least 1 MiB and at most 64 MiB. Without a limit, or
  when it cannot be read, the bound is 64 MiB. Under a 52Mi limit it is
  6.5 MiB; from a 512Mi limit up, it is 64 MiB.
- smock reads the limit once at startup, for this bound and the Journal's,
  and logs the bound with its `source`: `flag`, `variable`, `memoryLimit`
  (an eighth of the limit), `minimum` (1 MiB) or `default` (64 MiB), and
  the `memoryLimit` it read, or `memoryLimitError`, why it could not read
  one:

  ```json
  {"time":"2026-10-21T09:00:00.000Z","level":"info","msg":"state byte bound","maxBytes":6815744,"source":"memoryLimit","memoryLimit":54525952}
  ```

The bound keeps one count, up to date on each write:

- A space, one Mock with one Session or with no Session, counts its Mock
  name and its Session key once, plus 64 bytes, while it holds any
  Variable or [copy of a Data bucket](#copies-and-the-state-bound). The
  no-Session space has no key to count.
- Each Variable counts its name, 64 bytes, and its value.
- A value counts its compact JSON as smock writes it, plus 16 bytes for
  each JSON value in it: each object, array, string, number, boolean and
  null.
- Names, Session keys and JSON count their bytes in UTF-8.

So `count: 1`, the only Variable of the Mock `shop` in the Session
`run-42`, counts 74 bytes for its space (4 + 6 + 64) and 86 for itself
(5 + 64 + 1 + 16). The fixed bytes keep long Session keys and many tiny
values from taking far more memory than the bound counts. A write that
replaces a value counts the new size in place of the old. When a space
holds nothing more, its bytes go too, so resets and reloads that drop
Variables give their bytes back. Scenario state does not count, and
is not bounded.

A request whose writes would take the count above the bound writes none of
them. Under `smock serve --state-max-bytes 1048576`, with this Stub:

```yaml
- id: add-cart-item
  mock: shop
  request: { method: POST, path: /cart/items }
  variables:
    last: ${body}
  response: { status: 201 }
```

a request whose body would take the count above 1 MiB gets 507, with
`Content-Type: application/json`:

```json
{"error":"state limit reached","stub":"add-cart-item","message":"the writes would take per-Session state from 1048000 to 1049100 bytes, above its bound of 1048576 (--state-max-bytes)"}
```

- No response is picked, and nothing is written.
- The Scenario move stands. The Stub's delay still applies, and a
  connection Fault still replaces the response, as for a template failure.
- The Journal entry records status 507, `responseIndex: null` and
  `variablesWritten: []`.
- A write that does not grow the count, such as one that replaces a value
  with a smaller one, always fits.

An Admin API set follows the same rule. One that would take the count
above the bound writes nothing and gets 507 `state_limit_reached`, in the
Admin API's error form, with the same message. A delete gives back the
Variable's bytes, and its space's when the space holds nothing more.

Two metrics on the admin port, without labels, show how close the process
is to the bound: `smock_state_bytes`, the bytes the count holds now, and
`smock_state_writes_refused_total`, the writes it refused, each refused
request and each refused Admin API set once. smock reads them when
`/metrics` is scraped. `smock render` and the Admin render operation write
nothing, so they never meet the bound.

### Errors when loading

A template problem found when the files are loaded is reported with the
file and the JSON Pointer of the field (for a body file, of `bodyFile`), and
a message that starts with `template:` and gives the column of the problem
in a one-line string, or its line and column in a text of several lines:

```text
users.yaml: /stubs/0/response/json/id: template: column 3: unknown helper "fake.phone": not one of the helpers smock has
users.yaml: /stubs/1/response/bodyFile: template: line 3, column 5: unknown helper "fake.nickname": not one of the helpers smock has
```

These are checked when the files are loaded:

- every name, loop variable and helper;
- an `env` name, which must be listed with `--template-env`;
- a `data` name, which must be a Data bucket of the Stub's Mock;
- the names of `variables`;
- the number of arguments of each call, and the kinds and bounds of its
  literal arguments;
- date formats, offsets and durations;
- the keys of `$each` and `$if` objects, and reserved keys;
- `${` in a key or in `Content-Type`;
- `json()` and `raw()` in `json`;
- a templated body file that is not UTF-8.

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
has none. A Stub with [`responses`](#several-responses) renders the
response the seed picks, and the rendering shows its index as
`responseIndex` (null for a Stub with `response`). `--response <i>` (the
Admin API's `response=<i>`) renders the response at index `i` instead,
from 0; a Stub with `response` takes 0 only, and a [CRUD
Stub](#rendering-a-crud-stub) none. An index the Stub does not have fails: the Admin API answers 400 `invalid_request`, and `smock render`
exits with status 1. A value that is not an integer from 0 to 99 is refused
before rendering: 400 `invalid_request`, or a usage error with status 2.
With the same time, seed and index, a rendering is the same on every run. A template that fails for the sample shows the 500 and the
error. A response that serves [byte ranges](#range-requests) answers the
sample's `Range` header, so the rendering shows the 206 or the 416 a
request would get.

An [LLM response](#llm-responses) renders as a request gets it. A sample
that gets a [stream](#streams), such as one whose body sets
`stream: true` for `openai-chat`, shows the events, each with its
[wait](#timing) as `delay`, and a null `body`. Any other sample shows the
JSON body. The seed fixes the ids and the waits, and the reply's time,
such as `created`, is the rendering's time. For the
[`slow-hello` Stub](#timing), with `sample.json` holding

```json
{"method": "POST", "path": "/v1/chat/completions",
 "body": "{\"model\": \"gpt-6-astra\", \"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}]}"}
```

this command lists the waits of the events, from the opening chunk to
`[DONE]`:

```sh
smock render --dir defs slow-hello --request sample.json --seed 7 | jq -c '[.response.events[].delay]'
# [0,824,27,20,38,19,40,38,26,28,0,0]
```

A rendering reads and writes no live [Variables](#variables), so it stays
the same on every run:

- The sample's optional `vars` object gives the Variables that templates
  read, by name: `"vars": {"user": "bob"}`. By default there are none.
  A `vars` that is not an object, or a name that is not a Variable name,
  makes the sample invalid.
- The rendering shows the values the Stub would write as `variables`, an
  object, empty when the Stub has no `variables`. They are rendered
  against the sample's `vars`, in the order written, and their helpers
  draw from the seed as a request's do. Nothing is written, so the state
  bound never applies to them.
- The response reads the sample's `vars` with the Stub's values written
  over them, as the response to a request sees its writes.
- A value that fails to render shows the 500 a request would get, with
  its `templateError` (an `at` under `/variables/NAME`), empty
  `variables` and `responseIndex: null`, even when `--response` names a
  response.

For the [`login` Stub above](#variables), a sample with the body
`{"user":"ann"}` and `"vars": {"user": "bob"}` shows
`"variables": {"user": "ann", "previous": "bob"}` and the response
`{"user":"ann","previous":"bob"}`.

A rendering reads and writes no Session's copy of a [Data
bucket](#data-buckets), so it stays the same on every run too:

- The sample's optional `data` object gives the value of a bucket of the
  Stub's Mock, by name, in place of its initial value:
  `"data": {"orders": [{"id": 1002, "status": "pending"}]}`. The buckets
  it does not name read their initial values. A name that is not a bucket
  of the Stub's Mock, or a value that breaks the [rules of a keyed
  bucket](#keys-and-key-texts), fails: the Admin API answers 400
  `invalid_data`, and `smock render` exits with status 1.
- The rendering shows the writes the Stub's
  [`dataWrites`](#writing-buckets-datawrites) would make as `dataWrites`,
  in order, empty when the Stub has none. Each is `{op, bucket, key,
  value}`: `key` is the rendered key, or null; `value` is the rendered
  value, with the [new key](#new-keys) filled in for an `append` to a
  keyed bucket, or null for `remove`. They render and apply to the
  sample's data as at the [match decision](#when-data-is-written), and
  their helpers and new `uuid` keys draw from the seed as a request's do.
  Nothing is written, so the state bound never applies to them.
- The response reads the sample's data after the writes, as the response
  to a request sees its writes.
- A key or a value that fails to render, or a write that cannot be applied
  to the sample's data, shows the 500 a request would get, with empty
  `dataWrites` and `variables`, and `responseIndex: null`. A key or a value
  that fails to render also fills `templateError`; a write that cannot be
  applied is named in the 500's body, `data write failed`.

For the [`pay-order` Stub](#writes-by-key), the sample

```json
{"method": "POST", "path": "/api/v1/orders/1002/pay",
 "data": {"orders": [{"id": 1002, "status": "pending"}]}}
```

with `--time 2026-10-12T14:30:05Z` shows the `merge` it would make, and
the order after it:

```json
"dataWrites": [{"op": "merge", "bucket": "orders", "key": "1002",
  "value": {"status": "paid", "paidAt": "2026-10-12T14:30:05.000Z"}}]
```

and the response `{"id":1002,"status":"paid","paidAt":"2026-10-12T14:30:05.000Z"}`.
The same sample with the path `/api/v1/orders/9999/pay` shows `dataWrites:
[]` and the 500 `data write failed`, since the sample's data has no order
9999.

#### Rendering a CRUD Stub

A [CRUD Stub](#crud-stubs) renders the answer its operation would give to
the sample, from the sample's data, or else from the bucket's initial
value. Its failures, such as a 404 or a 409, and its [list
queries](#list-queries) render too.

- A create, replace, update or delete shows its write as `dataWrites`,
  with the op that makes the [same write](#writes): `append` for a
  create, with the new key filled in; `set` for a replace and `merge` for
  an update, with the item path's key and the body as sent; and `remove`
  for a delete, with the key. A list or a read, and a write that fails,
  show `dataWrites: []`.
- A new `uuid` key draws from the seed, as a request's does.
- `responseIndex` is null and `variables` is empty. `failed` is empty too,
  since a sample that fits an operation fails neither of the Stub's [two
  conditions](#a-crud-stubs-near-miss). A CRUD Stub has no responses, so
  `--response` (`response`) fails.
- A sample whose method and path fit no operation of the Stub, such as
  `DELETE /api/v1/orders`, has nothing to render: `smock render` exits
  with status 1, and the Admin API answers 400 `invalid_request`.

For the [`orders` CRUD Stub](#crud-stubs), the sample

```json
{"method": "POST", "path": "/api/v1/orders",
 "body": "{\"customerId\":42,\"status\":\"pending\"}"}
```

shows the `append` it would make to the three orders of `orders.json`:

```json
"dataWrites": [{"op": "append", "bucket": "orders", "key": null,
  "value": {"customerId": 42, "status": "pending", "id": 1004}}]
```

and the 201 with `Location: /api/v1/orders/1004` and the body
`{"customerId":42,"status":"pending","id":1004}`. The sample

```json
{"path": "/api/v1/orders", "query": {"status": "pending"},
 "data": {"orders": [{"id": 1, "status": "pending"},
                     {"id": 2, "status": "paid"}]}}
```

shows the list `[{"id":1,"status":"pending"}]`, with `X-Total-Count: 2`
and `X-Filtered-Count: 1`, and `dataWrites: []`.

## Data buckets

A *Data bucket* is a named JSON value that a Mock declares in Definition
files, with its initial value. Templates read it as `data.NAME`:

```yaml
data:
  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
  - { mock: shop, name: visits, json: 0 }
stubs:
  - id: list-orders
    mock: shop
    request: { method: GET, path: /api/v1/orders }
    response: { status: 200, template: true, json: "${data.orders}" }
```

With `files/orders.json` holding orders 1001 to 1003, `GET /api/v1/orders`
answers the three orders. Each Session reads the initial value until it
first writes to the bucket, which gives it its own copy ([Session
copies](#session-copies)).

### Declaring a bucket

The top-level `data` of a Definition file, beside `mocks` and `stubs`, is
a list of buckets. Each entry has these members, and no others:

| Member | Value |
|---|---|
| `mock` | The name of the bucket's Mock. Some file must declare it. Required. |
| `name` | 1 to 128 ASCII letters, digits, `_` and `-`, unique within the Mock. Required. |
| `json` | The initial value, inline: any JSON value. `json: null` counts as given. |
| `jsonFile` | The initial value, from a JSON file in the body-file subdirectory, such as `orders.json`. |
| `key` | Makes the bucket keyed: the name of the member that holds each item's key. |
| `newKey` | How a keyed bucket makes new keys: `integer` (the default) or `uuid`. |

- Give exactly one of `json` and `jsonFile`.
- A bucket may sit in any file, apart from its Mock, so it can sit beside
  the Stubs that use it. A Stub may read a bucket declared in any file,
  earlier or later.
- Two Mocks may use the same name. Each has its own bucket.
- `newKey` needs `key`. [New keys](#new-keys) says what it does.
- A keyed bucket can be served by a [CRUD Stub](#crud-stubs).

### Initial values

The initial value is static JSON. It is never templated, so every Session
starts from the same value, on every replica and in every run. Bulk data
comes from a script, or from a [configuration
language](#writing-definition-files-in-another-configuration-language).

A `jsonFile` follows the path rules of `bodyFile`: the path stays inside
the body-file subdirectory, and none of its names start with `.`. The file
must be JSON in UTF-8. It follows the rule of a JSON Definition file: a
key repeated in one object is an error (`duplicate key`, at the later
key), since JSON parsers disagree on which value counts. A missing file,
or one that breaks these rules, is an error when loading. smock reads the
file with the body files, so it is part of the digest, and editing it
triggers a [reload](#reloading).

### Keys and key texts

`key: id` makes a bucket keyed. The member name is taken literally:
`key: a.b` names the member `a.b`, not a nested one. There is no default
key.

- A keyed bucket's value is an array of objects.
- Each object has the key member. It holds a non-empty string without
  `/`, or an integer: a whole number from -(2^53 - 1) to 2^53 - 1.
- A key's *text* is the string, or the integer's digits, with `-` when it
  is negative and no leading zeros. `42`, `42.0` and `4.2e1` all have the
  text `42`.
- A number is judged by its 64-bit floating-point value, as JSON parsers
  commonly read it, not by its digits. So `1.0000000000000001`, which reads
  as 1, is the key `1`.
- No two items have the same key text, so `42` and `"42"` collide.

A key cannot hold `/`, since a path segment cannot carry it once
percent-decoded. Every write keeps these rules, [writes by
key](#writes-by-key) and the Admin API included. In an initial value,
they are errors when loading, reported with the JSON Pointer of the item
or its key. For a `jsonFile`, the problem is reported at `jsonFile`, with
the file's name and the pointer in it:

```text
shop.yaml: /data/0/json/2/id: has the key text "1001", as item 0 does
shop.yaml: /data/1/jsonFile: "orders.json" at /3: needs the key member "id"
```

### Reading buckets in templates

`data.NAME` gives the bucket's value with its own type, in any template
of a Stub of the bucket's Mock, the values of `variables` included.

```yaml
- id: summary
  mock: shop
  request: { method: GET, path: /api/v1/summary }
  response:
    status: 200
    template: true
    headers: { X-Visits: "${data.visits}" }
    json:
      count: ${len(data.orders)}
      first: ${data.orders[0].id}
      ids: { $each: data.orders, as: o, do: "${o.id}" }
```

- Steps go into the value: `${data.orders[0].id}`. `data['orders']` is the
  same as `data.orders`.
- [`find`](#helpers) picks an item by its key:
  `${find(data.orders, 'id', path[3]) ?? null}` answers the order of
  `/api/v1/orders/1002`, whose `id` is `1002` or `"1002"`.
- [`last`](#helpers) reads the last item: `${last(data.orders).id}`.
- The first step must name a bucket of the Stub's Mock. An unknown name,
  an index (`${data[0]}`) and `${data}` alone are errors when loading. A
  loop variable cannot be named `data`.
- A request that the [Default Mock](#hosts-and-the-default-mock) answers
  reads the Default Mock's buckets.
- A template reads the copy of the request's Session when it holds one,
  and else the initial value ([Session copies](#session-copies)).
- An [Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs) reads the
  buckets of its Mock, and the copies of its Session. After a reload
  removes a bucket, its reads of that bucket are missing, so `??` gives a
  fallback.

### Session copies

A Session reads a bucket's initial value until it first writes to the
bucket. That write gives the Session its own copy, which its requests read
from then on. Other Sessions still read the initial value, or their own
copies. A Stub writes with [`dataWrites`](#writing-buckets-datawrites),
and a test can set its Session's copy through the Admin API ([Data buckets
through the Admin API](#data-buckets-through-the-admin-api)).

- Reads never copy, so a Session that only reads costs no memory.
- Copies are kept per Mock, per
  [Session](../README.md#sessions-and-ephemeral-stubs) and per bucket, in
  the process. Requests without a Session share one copy of each bucket,
  as they share Scenario state.
- Each replica keeps its own copies, and they are lost on restart.
- A copy lives until a [reset](#copies-in-resets-and-reloads), a
  [reload](#reloading) that drops it, an Admin API drop, or a restart.
  Nothing expires it, so a test's outcome never depends on its timing.
- `smock render` and the Admin render operation read the sample's `data`,
  or else each bucket's initial value, also when the sample names a
  Session that holds a copy. A rendering never reads or writes a Session's
  copy ([Rendering a template](#rendering-a-template)).

### Writing buckets: `dataWrites`

A Stub's `dataWrites` writes to the buckets of its Mock when the Stub
matches. The writes go to the copies of the request's Session:

```yaml
data:
  - { mock: shop, name: visits, json: 0 }
stubs:
  - id: visit
    mock: shop
    request: { method: GET, path: /visit }
    dataWrites:
      - { op: set, bucket: visits, value: "${add(data.visits, 1)}" }
    response: { status: 200, template: true, json: { visits: "${data.visits}" } }
```

Three calls in one Session answer `{"visits":1}`, `{"visits":2}` and
`{"visits":3}`. Another Session starts again from 1.

- `dataWrites` is a list of 1 to 100 writes, applied in order. It sits
  beside `response` or `responses`, so a Stub writes once, whichever
  response is picked.
- Each write has `op`, `bucket`, and the members its op takes, and no
  others:

  | `op` | Members | Effect |
  |---|---|---|
  | `set` | `value`, optional `key` | The bucket becomes the value. With `key`, the item with that key does, in its place. |
  | `merge` | `value`, optional `key` | A shallow merge of the value, an object, into the bucket, which must hold an object. Each member replaces the member of the same name in its place, or is added at the end. `null` is stored as null. With `key`, the merge is into the item with that key. |
  | `append` | `value` | The value is appended to the bucket, which must hold an array. In a keyed bucket, it is an item, which gets a [new key](#new-keys) when it has none. |
  | `remove` | `key` | The item with that key is removed from the keyed bucket. |

- `bucket` names a bucket of the Stub's Mock, as written. It is never a
  template.
- `value` is any JSON. It is always a [structured
  template](#structured-templates), whether or not a response has
  `template: true`: `${…}` inserts a value, and `$${` writes `${`. As at
  the root of `json`, a `$if` at its root needs `else`.
- `key` names one item of a keyed bucket. It is a text template, always
  parsed, and its output is compared as a [key text](#keys-and-key-texts).
  Only a keyed bucket takes it ([Writes by key](#writes-by-key)).
- Each key and each value is bounded as a rendered body is: at most 1 MiB
  of output, and at most 10,000 loop iterations. Past either is a render
  error.
- A counter is a `set` with a helper, as above. `merge` and `append` keep
  the rest of the bucket: `{ op: append, bucket: cart, value: "${body}" }`
  adds the request's body to a cart.
- An [Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs) takes
  `dataWrites` too, over the buckets of its Mock, and writes the copies of
  its Session.

#### Writes by key

A keyed bucket is written item by item. `set`, `merge` and `remove` take
the `key` of the item, and `append` adds one:

```yaml
- id: pay-order
  mock: shop
  request: { method: POST, path: { pattern: "/api/v1/orders/[^/]+/pay" } }
  dataWrites:
    - { op: merge, bucket: orders, key: "${path[3]}", value: { status: paid, paidAt: "${now()}" } }
  response:
    status: 200
    template: true
    json: "${find(data.orders, 'id', path[3])}"
```

`POST /api/v1/orders/1002/pay` marks order 1002 paid for that Session,
and answers the paid order, which [`find`](#helpers) picks.
`POST /api/v1/orders/9999/pay` answers 500 `data write failed`, since no
order has that key, and writes nothing.

- `key` is compared as a key text, so `${path[3]}` finds the order whose
  `id` is `1002` or `"1002"`. A key that no item has fails the write: a
  missing item is never skipped, so a Stub never answers as if the item
  were there.
- `set` with `key` makes the item the value, an object, in its place.
  `merge` with `key` merges the value, an object, into the item, as
  `merge` merges into a bucket.
- The value's key member may be absent, or hold the item's key text. The
  item keeps its stored key value, so `42` stays a number when the value
  holds `"42"`. When `set` gives no key member, the key is added as the
  item's last member. Any other key fails the write.
- `remove` removes the item.
- `append` adds the value, an object, at the end. A key member that holds
  a valid key that no item has is kept. A value without the key member
  gets a [new key](#new-keys), added as its last member.
- `set` without `key` replaces the whole bucket. Its value must keep the
  [rules of keyed buckets](#keys-and-key-texts).
- `merge` without `key` cannot write to a keyed bucket, which holds an
  array. It is an error when loading.

A Stub's response reads the bucket after its own writes, so
`${last(data.orders)}` answers the item that its `append` just added, new
key included, as the [`last` example](#helpers) shows. A [CRUD
Stub](#crud-stubs) answers what it creates.

As for other writes, only a Session's first write to a bucket copies it,
and the [state bound](#copies-and-the-state-bound) counts what each item
changed.

#### New keys

A keyed bucket makes a key for an item that `append` adds without one, as
its `newKey` says:

- `integer`, the default: one more than the highest integer key, or 1
  when there is none. String keys are not counted, but when a string key
  already has the new key's text, the next integer is tried, until one is
  free. A deleted highest key can be given again.
- `uuid`: a version 4 UUID, as `fake.uuid()` makes it, drawn again while
  an item has it. It comes from the request's helpers, so [`fault.seed`
  and `--seed`](#seeds) repeat it.

When the new integer key would pass 2^53 - 1, the write fails with
`no new key`, and nothing is written.

#### When data is written

The writes are made at the match decision, together with the Stub's
[Variables](#when-variables-are-written), in this order:

1. The Scenario moves, and the request takes its one random draw.
2. Each write's bucket is checked first. This matters only for an
   Ephemeral Stub after a reload ([When a write fails](#when-a-write-fails)),
   and it draws nothing. Then the value of each Variable is rendered, then
   each write, in the order written, its `key` before its `value`, all
   against the state from before this request, Variables included. So
   `${add(data.visits, 1)}` counts, and a write that reads `vars.NAME` sees
   the Variable as it was before the request.
3. The writes are applied in order, as if to working copies of the
   buckets: a write sees what the writes before it did. New keys are made
   here.
4. The [state bound](#copies-and-the-state-bound) is checked.
5. The Variables and the copies are stored at once.
6. The response is picked, rendered and planned. It sees the data after
   the writes.

The helpers draw for the values of the Variables first, then for each
write's key and value, then for the new `uuid` keys, in write order, then
for the response, so [`fault.seed` and `--seed`](#seeds) replay them.

Only a Session's first write to a bucket copies the bucket. Later writes
change the copy in place, and the state bound counts what each adds or
replaces, without measuring the copy again.

Once stored, the writes stand: a delay, a connection Fault, a response
that fails to render, a client that leaves, or a Journal that is off does
not undo them. Each request sees the writes of every request that reached
smock before it, also while that request's delay still runs.

#### When a write fails

The writes are all or nothing. When any of steps 2 to 4 fails, nothing is
written, Variables included:

- A key or a value that fails to render gives the [template
  failure](#missing-values-and-render-errors): 500, with an `at` under
  `/dataWrites/<i>/key` or `/dataWrites/<i>/value`.
- A write that cannot be applied gives 500, with
  `Content-Type: application/json`, the write's pointer and what went
  wrong:

  ```json
  {"error":"data write failed","stub":"visit","at":"/dataWrites/0","message":"the Data bucket \"visits\" holds a number, and \"merge\" needs an object"}
  ```

  These writes cannot be applied:

  - a `merge` whose value is not an object, a `merge` into a bucket that
    holds no object, and an `append` to a bucket that holds no array;
  - a write by key that names a key that no item has;
  - a write that would break the rules of a keyed bucket: an `append` or
    an item `set` or `merge` whose value is not an object, an item `set`
    or `merge` whose value holds another key, an `append` whose key is
    not a key or is another item's, and a `set` without `key` whose value
    is not an array of objects with valid, unique keys;
  - an `append` when no integer key is left (`no new key`).
- Writes that would pass the state bound get 507, as Variables do, and
  count in `smock_state_writes_refused_total`.

After any of these, no response is picked. The Scenario move stands, the
Stub's delay still applies, and a connection Fault still replaces the
answer, as for a template failure.

An Ephemeral Stub is not read again at a reload. Its write fails to apply
in the same way, and nothing is written, when a reload removes its
bucket, takes `key` from the bucket of a write with `key`, or gives `key`
to the bucket of a `merge` without `key`. smock checks each write's
bucket this way before any value or key renders, Variables included, and
the check draws nothing. So a value that reads the removed bucket without
`??`, such as `${add(data.visits, 1)}`, does not turn this into a
template failure:

```json
{"error":"data write failed","stub":"eph-1","at":"/dataWrites/0","message":"the Mock has no Data bucket \"visits\" since a reload"}
```

A `set` or `append` without `key` still applies when a reload gives its
bucket `key`, and fails only when what it writes breaks the bucket's
rules. When every write's bucket is still there, the Stub's template
reads of a removed bucket are missing, so `??` gives a fallback.

These are errors when loading, reported by `smock check`, at startup, by
a reload, which then keeps the files it serves, and as 400 `invalid_stub`
for an Ephemeral Stub:

- a bucket that is not one of the buckets of the Stub's Mock;
- an op given a member it does not take, or without one it needs, such as
  `append` with `key` or `set` without `value`;
- `dataWrites` with no write, or with more than 100;
- `key` on a bucket without `key`, and `merge` without `key` on a keyed
  bucket;
- a literal value, one with no `${`, `$each` or `$if`, that already breaks
  its op: a `merge` value that is not an object, an item that `set` or
  `merge` with `key` writes or that `append` adds to a keyed bucket that
  is not an object, a key member of such an item that holds no key, a
  key member of a `set` or `merge` item that holds a key other than a
  literal `key`, and a `set` value without `key` that breaks the rules of
  a keyed bucket.

#### Writes in the Journal

Each [Journal](../README.md#the-journal) entry names the buckets its
request wrote, in the order first written, each once, as `dataWritten`.
`dataError` is the `at` and the `message` of a write that failed to
apply, as the 500 gives them, or null. Both are always present, and count
toward the entry's bytes.

- A request whose writes fail to render or to apply, or meet the state
  bound, records `dataWritten: []`, `variablesWritten: []` and
  `responseIndex: null`. A key or a value that fails to render also
  records `templateError`.
- A response that fails to render after the writes were stored lists
  them, since nothing undoes them.

`smock render` and the Admin render operation show the writes a Stub
would make, from sample data, and write nothing ([Rendering a
template](#rendering-a-template)).

### CRUD Stubs

A *CRUD Stub* serves a keyed bucket as a REST resource: it lists and
creates items at its path, and reads, replaces, updates and deletes one
item at the path plus its key. It has `crud` in place of `request` and
`response`:

```yaml
data:
  - { mock: shop, name: orders, key: id, jsonFile: orders.json }
stubs:
  - id: orders
    mock: shop
    crud:
      bucket: orders
      path: /api/v1/orders
      headers: { Access-Control-Allow-Origin: "*" }
```

With `files/orders.json` holding orders 1001 to 1003,
`GET /api/v1/orders` answers 200 with the three orders, `X-Total-Count: 3`,
`X-Filtered-Count: 3` and the CORS header. `GET /api/v1/orders/1002`
answers order 1002. `GET /api/v1/orders/9999` answers 404, with the CORS
header too:

```json
{"error":"no item with this key","stub":"orders","key":"9999"}
```

A Session that sends `POST /api/v1/orders` with
`{"customerId":42,"status":"pending"}` gets 201,
`Location: /api/v1/orders/1004` and
`{"customerId":42,"status":"pending","id":1004}`. Its
`GET /api/v1/orders/1004` then answers that order, and its
`DELETE /api/v1/orders/1004` answers it once more and removes it. Another
Session still sees the three orders.

A list can be filtered, sorted and paged with a
[list query](#list-queries). `smock render` shows what a CRUD Stub would
answer to a sample request ([Rendering a CRUD
Stub](#rendering-a-crud-stub)).

#### The shape of a CRUD Stub

`crud` has these members, and no others:

| Member | Value |
|---|---|
| `bucket` | A keyed bucket of the Stub's Mock ([Keys and key texts](#keys-and-key-texts)). Required. |
| `path` | The list path, such as `/api/v1/orders`. Required. |
| `headers` | Headers for every answer of the Stub ([CRUD headers](#crud-headers)). |

- Beside `crud`, the Stub may have `id`, `mock`, `priority` and
  [`fault`](#faults). `request`, `response`, `responses`, `scenario`,
  `variables` and `dataWrites` are not allowed. A Stub has exactly one of
  `response`, `responses` and `crud`.
- Two CRUD Stubs may have the same `path`. The first in the order answers,
  and `smock check` [warns](#a-stub-that-can-never-match) about the other.

#### CRUD paths

- `path` starts with `/`, does not end with `/`, and has no empty segment.
  So `/` alone is not a path.
- The list path is `path`. An item path is `path`, then `/`, then one
  non-empty segment: the key text.
- Both are compared with the percent-decoded path, byte for byte, as
  [`path` conditions](#how-a-stub-matches-a-request) compare it. So
  `/api/v1/orders/` and `/API/v1/orders` are not served. A key sent with
  `%2F` is never reached, since it decodes to a deeper path.

#### Reads

| Request | Answer |
|---|---|
| `GET <path>` | 200, the items that its [list query](#list-queries) keeps, as a plain JSON array, with `X-Total-Count` and `X-Filtered-Count`. Without a query, every item, and both counts are the number of items. 400 when smock cannot read the query. |
| `GET <path>/<key>` | 200, the item whose key has the text `<key>`, or 404 with the body above. |

- A read sees the copy of the request's Session when it holds one, and
  else the initial value ([Session copies](#session-copies)). A read never
  copies.
- Keys compare by their text ([Keys and key texts](#keys-and-key-texts)).
  So `/api/v1/orders/1002` finds the order whose `id` is `1002` or
  `"1002"`, but `/api/v1/orders/01002` finds none.
- A request body is ignored.
- Every answer is compact JSON with `Content-Type: application/json`, its
  numbers written as smock writes them, so a stored `9.90` comes back as
  `9.9`. The answers are not templates, so the 1 MiB bound on a rendered
  body does not apply: a list is as large as its bucket.
- The 404 and the 400 are the CRUD Stub's own answers. The request counts
  as matched, under the Stub's ID, and gets no
  [Near miss](#when-no-stub-matches).

#### List queries

A list reads its query in smock's own syntax: filters by member, `$sort`,
`$offset` and `$limit`. So
`GET /api/v1/orders?status=paid&$sort=-id&$limit=10` lists the paid
orders, highest `id` first, at most ten. A read ignores the query.

Parameters are decoded as [`query` conditions](#how-a-stub-matches-a-request)
decode them: `%20` and `+` both stand for a space, and a parameter without
`=` has the empty value.

**Filters.** A name that does not start with `$` filters on the item
member of that name.

- Names are top-level members, taken literally: `a.b` names the member
  `a.b`, not `b` inside `a`.
- Every name must hold. A repeated name holds when any of its values does,
  so `?status=paid&status=pending` lists both.
- A member meets a value as [`find`](#helpers) compares: a string equal to
  the value; a number of equal value, so `?total=12.5` finds `12.50`, and
  integers beyond 2^53 compare exactly; `true`, `false` and `null` by
  those words. So `?id=1002` finds the order whose `id` is `1002` or
  `"1002"`. Objects, arrays and absent members never meet a value.

**Names that start with `$`** are smock's. `$sort`, `$offset` and `$limit`
are read below, and `$$name` filters on the member `$name`. Any other
name that starts with `$` is 400, so an OData client's `$top` gets an
error rather than a wrong list.

**Sort.** `$sort=customerId,-total` sorts by `customerId`, ascending, and
then, among items that tie, by `total`, descending.

- The value is a comma-separated list of member names, each after an
  optional `-`. Names are literal, and `$$` is not an escape here. A
  member whose name starts with `-` or holds `,` cannot be a sort key.
- Ascending, values order by type first: null, false, true, numbers,
  strings. Numbers order by value, compared as `json` conditions compare
  them, so large integers order exactly. Strings order by Unicode code
  point, case-sensitive, with no locale rules: `B` comes before `a`.
  Descending reverses that whole order.
- Items whose member is absent, an object or an array go last, in either
  direction. They tie with each other on that member, so the next sort
  key, or the bucket's order, decides between them.
- The sort is stable: items that tie keep the bucket's order. Without
  `$sort`, items keep the bucket's order.

**Paging.** `$offset` skips that many items, 0 by default. `$limit` keeps
at most that many, with no limit by default.

- Both are decimal digits: `$offset` from 0 and `$limit` from 1.
- A number too large to hold counts as the largest: an offset past the
  end gives `[]`, and such a limit keeps every item.

**Order and counts.** The list applies the filters, then `$sort`, then
`$offset` and `$limit`, wherever they stand in the query. Every 200 list
answer carries `X-Total-Count`, the number of items in the bucket, and
`X-Filtered-Count`, the number that pass the filters, before paging. The
body stays the plain array.

**Errors.** A query that smock cannot read answers 400 with the Stub's
`crud.headers` and without the two counts, since it lists nothing. It
names the first such parameter in the query:

```json
{"error":"invalid query parameter","stub":"orders","parameter":"$top"}
```

These are 400: a name that starts with `$` other than the three above; an
empty sort name, as in `$sort=`, `$sort=a,,b` or `$sort=-`, or one that
starts with `-`, as in `$sort=--a`; an `$offset` or a `$limit` that is not
decimal digits, or a `$limit` of 0; and `$sort`, `$offset` or `$limit`
given twice.

**A client's own parameters are filters too.** A client that sends its
own paging or tracking parameters, such as `page` or `_`, gets `[]` with
`X-Filtered-Count: 0`, since no item has the member `page` or `_`. An
ordinary Stub before the CRUD Stub can answer such lists from
[`data.NAME`](#reading-buckets-in-templates):

```yaml
- id: orders-by-page
  mock: shop
  request:
    method: GET
    path: /api/v1/orders
    query: { page: { $exists: true } }
  response:
    status: 200
    template: true
    json: "${data.orders}"
- id: orders
  mock: shop
  crud: { bucket: orders, path: /api/v1/orders }
```

#### Writes

| Request | Answer |
|---|---|
| `POST <path>` | create: 201, the item stored, with `Location`. |
| `PUT <path>/<key>` | replace: 200, the item stored. |
| `PATCH <path>/<key>` | update: 200, the item stored. |
| `DELETE <path>/<key>` | delete: 200, the item removed. |

Each is one [write by key](#writes-by-key), the one that `dataWrites`
makes with the same op: a create is an `append`, a replace a `set` with
`key`, an update a `merge` with `key`, and a delete a `remove`.

- A create adds the item at the end of the bucket.
- A replace makes the body the item, in its place.
- An update merges the body into the item, shallowly: each member replaces
  the member of the same name, in its place, and new members are added at
  the end, in body order. `null` is stored as null.
- A delete removes the item, and answers it.
- The write goes to the copy of the request's Session. A Session's first
  write copies the bucket, and later ones change that copy
  ([Session copies](#session-copies)). Requests without a Session share
  one copy.

The request body:

- It is parsed as JSON whatever its `Content-Type`, as
  [`json` conditions](#how-a-stub-matches-a-request) parse it, within
  `--body-limit`.
- A create, replace or update needs a JSON object. Anything else, no body,
  a body that is not JSON, an array or a scalar, gets 400
  `body is not a JSON object`.
- A delete ignores any body.

Keys:

- A create whose body has no key member gets a [new key](#new-keys),
  added as the item's last member. A body whose key member holds a valid
  key that no item has keeps it. A key member that holds no valid key,
  `null` included, gets 400 `invalid key`. A key that an item has gets
  409 `key already exists`.
- A replace or update keeps the item's key. The body's key member may be
  absent, or hold the item's key text. Any other key gets 400
  `key does not match the path`. The item keeps its stored key value, so
  `42` stays a number when the body sends `"42"`, and a replace whose body
  has no key member gets the key as its last member.
- A replace, update or delete of a key that no item has gets 404, as a
  read does.
- `Location` is the new item's path: each segment of `path`, then the key
  text, each after a `/`, and percent-encoded as
  [`urlEncode`](#helpers) encodes it. So the key `a b` under
  `/api/v1/orders` gives `/api/v1/orders/a%20b`.

So `PATCH /api/v1/orders/1004` with `{"status":"paid","id":"1004"}`
answers `{"customerId":42,"status":"paid","id":1004}`.

A write that fails writes nothing, and gets one of these answers. Each
body is compact JSON, `{"error": "<what>", "stub": "<id>", ...}`:

| Status | `error` | When |
|---|---|---|
| 400 | `body is not a JSON object` | A create, replace or update whose body is not a JSON object. |
| 400 | `invalid key` | A create whose body's key member holds no valid key. |
| 400 | `key does not match the path` | A replace or update whose body's key member holds another key. |
| 404 | `no item with this key` | A replace, update or delete of a key that no item has. The body has `key`. |
| 409 | `key already exists` | A create whose body's key an item has. The body has `key`. |
| 500 | `no new key` | A create when the next integer key would pass 2^53 - 1. |
| 507 | `state limit reached` | A write past [the state bound](#copies-and-the-state-bound). The body has `message`, as for other writes. |

These are the CRUD Stub's own answers. The request counts as matched,
under the Stub's ID, and gets no Near miss.

#### When a CRUD Stub writes

The write is made at the match decision, as
[`dataWrites`](#when-data-is-written) are: the request takes its one
random draw, the write is applied to a working copy, the state bound is
checked, and the copy is stored. Only then is the answer sent, after any
delay.

- Once stored, the write stands. A delay, a connection Fault, a client
  that leaves, or a Journal that is off does not undo it.
- Each request sees the writes of every request that reached smock before
  it. So two creates whose answers are both delayed still get different
  keys.
- A new `uuid` key comes from the request's helpers, seeded with its one
  draw, as a response's first `fake.uuid()` would. So
  [`fault.seed` and `--seed`](#seeds) repeat it, and the Fault decisions
  do not move it.
- A write that would take the count of per-Session state above
  [the bound](#copies-and-the-state-bound) gets 507, writes nothing, and
  counts in `smock_state_writes_refused_total`. A delete can get it too,
  since a Session's first write copies the whole bucket.

#### Order and overrides

A CRUD Stub matches only the requests it serves. Any other method or path
shape does not match it: `HEAD` and `OPTIONS`, `PUT`, `PATCH` and `DELETE`
on the list path, `POST` on an item path, and paths deeper than an item
path. Later Stubs are tried, then the Mock's
[no-match answer](#when-no-stub-matches). Methods are compared exactly.

A CRUD Stub is tried in [the usual order](#which-stub-answers). It has no
conditions and no Scenario clause of its own, so an earlier Stub takes
over one of its requests:

```yaml
- id: no-token
  mock: shop
  request: { headers: { authorization: { $exists: false } } }
  response: { status: 401, json: { error: unauthorized } }
- id: orders-down
  mock: shop
  scenario: { name: orders, requires: Down }
  request: { path: { pattern: "/api/v1/orders(/[^/]+)?" } }
  response: { status: 503 }
- id: orders
  mock: shop
  crud: { bucket: orders, path: /api/v1/orders }
```

A request without `Authorization` gets 401, and a request of a Session
whose Scenario `orders` is in `Down` gets 503. Every other request to the
orders gets the CRUD Stub's answer. A lower `priority` than the CRUD
Stub's places a Stub before it wherever it is declared.

An override placed after the CRUD Stub never answers. `smock check`
[warns](#a-stub-that-can-never-match) about a Stub with a `method` and an
exact `path` that an earlier CRUD Stub serves, such as one for
`GET /api/v1/orders/1001` after the `orders` CRUD Stub.

#### A CRUD Stub's Near miss

A CRUD Stub can be the [Near miss](#when-no-stub-matches) of a request
that no Stub matches. It counts two conditions:

- `path` fails when the request path is neither the list path nor an item
  path. It expects `{"crud": "<path>"}`.
- `method` fails when the Stub does not serve the method at the request
  path's shape: `GET` and `POST` at the list path, and `GET`, `PUT`,
  `PATCH` and `DELETE` at an item path. When `path` fails too, the method
  is judged at either shape. It expects `{"crud": [<methods>]}`: those
  methods, each once, in the order `GET`, `POST`, `PUT`, `PATCH`,
  `DELETE`.

What the request sent is its method, or its percent-decoded path, as for
any Stub. A CRUD Stub competes with the Mock's other Stubs by the same
rules: the fewest failed conditions, and the one tried first on a tie.
With only the `orders` CRUD Stub, `HEAD /api/v1/orders` gets the no-match
answer with

```http
Smock-Near-Miss: orders; failed=method
```

and the Journal shows the failed condition in full:

```json
{
  "condition": "method",
  "expected": { "crud": ["GET", "POST"] },
  "actual": ["HEAD"]
}
```

`GET /api/v1/orders/1001/items` fails only `path`, since the Stub serves
`GET` at both shapes. `HEAD /api/v1/orders/1001/items` fails both, and its
`method` expects all five methods.

#### CRUD headers

smock sets `Content-Type`, `Location` on a create, and `X-Total-Count`
and `X-Filtered-Count` on a list's 200. `crud.headers` adds static
headers to every answer of the Stub, errors, 500 and 507 included:

- It has the shape and rules of [`noMatch.headers`](#when-no-stub-matches):
  by name, a value or a non-empty array of values, each sent as its own
  field line, in order. Two names that differ only in case are an error.
  It is never templated.
- A header that smock sets cannot be given: `Content-Type`, `Location`,
  `X-Total-Count`, `X-Filtered-Count`, `Content-Length`,
  `Transfer-Encoding`, `Connection` and `Smock-Mock`. Names are compared
  case-insensitively.
- A browser reads `X-Total-Count` and `X-Filtered-Count` of a
  cross-origin answer only when `Access-Control-Expose-Headers` names
  them, which `crud.headers` can give:

  ```yaml
  headers:
    Access-Control-Allow-Origin: "*"
    Access-Control-Expose-Headers: X-Total-Count, X-Filtered-Count
  ```

- A CRUD Stub does not answer `OPTIONS`, so a browser's preflight needs a
  Stub of its own, as in [When no Stub matches](#when-no-stub-matches).

#### Faults on a CRUD Stub

[`fault`](#faults) works as on any Stub. Every matched request takes its
one draw, its 4xx and 5xx answers included, so [`fault.seed`](#seeds)
replays the same decisions. A delay comes before the answer, and after
the write. A connection Fault replaces the answer, but not the write, and
`partial` sends half of its body.

#### CRUD Stubs in the Journal

Each [Journal](../README.md#the-journal) entry has `crud`: null, or the
operation and its key. A list records `{"op":"list","key":null}`,
whatever its query. A read, a replace, an update and a delete record
`read`, `replace`, `update` and `delete` with the item path's key text,
whatever the outcome, such as `{"op":"read","key":"9999"}` for the 404
above. A create records `create` with the key of the item stored, the
body's key on a 409, and else null. `crud` counts toward the entry's
bytes, and `responseIndex` is null for a CRUD Stub's answers.

`dataWritten` names the bucket after a write, and is `[]` after a list, a
read, or any failure. `dataError` stays null: a CRUD Stub's failures are
its own answers.

#### Ephemeral CRUD Stubs

An [Ephemeral Stub](../README.md#sessions-and-ephemeral-stubs) can be a
CRUD Stub, with no `id` or `mock`, as any Ephemeral Stub. It serves the
requests of its Session, and reads and writes its Session's copy of the
bucket.

An Ephemeral Stub is not read again at a reload, so a CRUD Stub looks its
bucket up by name on each request. After a reload removes the bucket, it
answers 500 with its headers:

```json
{"error":"unknown data bucket","stub":"eph-1","bucket":"orders"}
```

After a reload takes the bucket's `key` away, it answers 500 with
`"error":"data bucket changed"`, and the same `stub` and `bucket`. Either
way, a create, replace, update or delete writes nothing.

#### CRUD Stubs that do not load

These are errors when loading, reported by `smock check`, at startup, by a
reload, which then keeps the files it serves, and as 400 `invalid_stub` for
an Ephemeral Stub:

- a `bucket` that is not one of the buckets of the Stub's Mock, or that
  has no `key`;
- a `path` that breaks the rules above;
- a member that the shape does not allow, beside `crud` or in it;
- a `crud.headers` name that smock sets.

`smock check` also [warns](#a-stub-that-can-never-match) when a CRUD Stub
hides a later Stub, or a Stub hides a later CRUD Stub.

### Data buckets through the Admin API

A test can arrange and inspect the data of its own Session through the
Admin API. Each operation names its Session as other Admin API calls do,
and one without a Session works on the Mock's no-Session space:

- `GET /v1/mocks/{mock}/data` lists the Mock's buckets by name, in
  byte-wise order, without their values. `key` and `newKey` are `null` for
  a bucket without `key`, and `newKey` is `integer` for a keyed bucket that
  gives none. `written` is true when the Session holds its own copy:

  ```json
  {"data":[{"name":"orders","key":"id","newKey":"integer","written":true},{"name":"visits","key":null,"newKey":null,"written":false}],"warnings":[]}
  ```

- `GET /v1/mocks/{mock}/data/{bucket}` reads one, with the value the
  Session reads, its copy or else the initial value:
  `{"bucket":{"name":"visits","key":null,"newKey":null,"written":false,"value":0},"warnings":[]}`.
- `PUT /v1/mocks/{mock}/data/{bucket}` sets the Session's copy. The body
  is the value itself, any JSON. It replaces the copy the Session had, and
  makes a copy even when the value equals the initial one. The reply is the
  bucket, as a read gives it.
- `DELETE /v1/mocks/{mock}/data/{bucket}` drops the Session's copy, so the
  bucket reads its initial value again. The reply is the bucket, as a read
  gives it, also when there was no copy.

So a test in the Session `checkout-42` that sends
`PUT /v1/mocks/shop/data/orders` with `[{"id":1,"status":"paid"}]` gets
that one order from `GET /api/v1/orders`, while another Session still gets
the three orders of `orders.json`. `DELETE /v1/mocks/shop/data/orders`
brings them back for `checkout-42`.

- A Mock that does not exist gets 404 `unknown_mock`, and a bucket that the
  Mock does not declare 404 `unknown_bucket`. Path segments are
  percent-decoded.
- A body that is not JSON gets 400 `malformed_json`, and a set without a
  body 400 `invalid_request`. `--body-limit` bounds the body.
- A value that breaks the rules of a keyed bucket ([Keys and key
  texts](#keys-and-key-texts)) gets 400 `invalid_data`, with each problem
  in the message, and writes nothing.
- A set keeps a number's value, not its text, as a [set of a
  Variable](#through-the-admin-api) does: `19.990` is stored as `19.99`
  and `1e3` as `1000`. Unlike a Variable's value, a bucket's value is not
  bounded at 1 MiB, since a bucket's writes can grow it past that anyway.
- A set counts against [the state bound](#copies-and-the-state-bound): one
  that would pass it gets 507 `state_limit_reached` and writes nothing. A
  drop gives back the bytes the copy counted.
- Another Session's copies are never listed, read, set or dropped, and no
  operation lists the Sessions.
- Each set, and each drop of a copy, writes a log entry that names the
  Mock, the Session and the bucket, but not the value. A drop logs
  `Data bucket copy dropped`:

  ```json
  {"time":"2026-10-22T09:00:00.000Z","level":"info","msg":"Data bucket set","mock":"shop","session":"checkout-42","bucket":"orders"}
  ```

### Copies in resets and reloads

A [reset](../README.md#sessions-and-ephemeral-stubs) drops the copies in
its scope, so that their buckets read their initial values again:

- `{"scope":"session"}` drops the calling Session's copies in every Mock,
  or those of requests without a Session when the call carries none;
- `{"scope":"mock","mock":"shop"}` drops every Session's copies of
  `shop`'s buckets, those of requests without a Session included;
- `{"scope":"all"}` drops every copy.

The reset answers how many copies it dropped, in `removed.dataBuckets`,
and its log entry says the same. Dropped copies give their bytes back to
[the state bound](#copies-and-the-state-bound). So after a test in the
Session `checkout-42` sets its copy of `orders`, `POST /v1/reset` with
`{"scope":"session"}` answers `"dataBuckets":1`, and the Session reads
`orders.json` again.

A [reload](#reloading) that swaps in new files keeps each copy whose bucket
it did not change, and drops the others:

- A copy is dropped when its Mock is gone, when the new files no longer
  declare its bucket, or when the bucket's initial value or `key` changed.
- The initial values are compared as compact JSON. So moving one between
  `json` and `jsonFile`, or reformatting its file, is no change.
- A change of `newKey` keeps the copies: their data stays valid, and only
  the keys made from then on change.
- A reload that fails, or finds the files unchanged, keeps every copy.

So editing an unrelated Stub keeps the data of tests in progress, but
editing a bucket's initial value resets every Session's copy of it.

### Copies and the state bound

Copies count toward [the state bound](#the-state-bound), together with
Variables, under one rule:

- A space, one Mock with one Session or with no Session, counts its Mock
  name and its Session key once, plus 64 bytes, while it holds any
  Variable or copy.
- Each copy counts its bucket's name, 64 bytes, and its value: its compact
  JSON as smock writes it, plus 16 bytes for each JSON value in it.
- Initial values do not count. They are part of the definition set, as
  body files are.

So `visits: 7`, the only copy of the Mock `shop` in the Session `run-42`,
counts 74 bytes for its space (4 + 6 + 64) and 87 for itself
(6 + 64 + 1 + 16). A Variable in the same space adds only its own bytes.
`smock_state_bytes` counts the copies too.

- A write that would take the count above the bound writes nothing and
  gets 507. It counts in `smock_state_writes_refused_total`.
- Reads never fail, also when the count is at the bound.
- A dropped copy gives its bytes back, and a space's bytes go when it
  holds nothing more.

Nothing expires a copy, so plan for growth:

- A copy costs the full size of its bucket for each Session that writes to
  it. A large bucket that many Sessions write fills the bound fast.
- Give each virtual user of a load test one Session, and reset it at the
  end.
- A bucket whose initial value alone counts more than the bound refuses
  every write whose copy does not fit, such as a write that leaves the
  bucket as large as it started. `smock check` cannot see this, since it
  does not know the bound.

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
  closes the connection. The client sees a response cut short. For a 206
  to a [Range request](#range-requests), the body is the range. For
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
apply, and how long the delay is, and, for a Stub with
[`responses`](#several-responses), which response it gets.

- A Stub with a `seed`, from 0 to 9007199254740991, has its own generator.
  smock creates it when it loads the Definition files, and again from the
  seed when a [reload](#reloading) swaps in a new definition set, and it
  advances once per request the Stub matches. An Ephemeral Stub with a seed
  gets its own generator when it is added, which a reload keeps. So the n-th
  request a seeded Stub matches gets the same Faults in every run, whatever
  requests other Stubs get, the same response among `responses`, the same
  [ids in an LLM reply](#ids-seeds-and-time) and the same
  [waits of an LLM stream](#timing). The generator is a fixed algorithm,
  the same on every platform.
- Stubs without a seed draw from the process generator, which they share.
  smock picks its seed at startup and logs it:

  ```json
  {"time":"2026-10-13T09:12:44.512Z","level":"info","msg":"random seed","seed":5126750341862113}
  ```

  To replay a run, start smock with that seed (`--seed`, `SMOCK_SEED`): the
  same requests in the same order then get the same Faults and the same
  responses.

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
- [Variables](#variables) survive the swap. Those of a Mock that is gone
  are dropped with it.
- [Copies of Data buckets](#session-copies) survive the swap while their
  bucket stays as it was. A copy is dropped when its Mock is gone, when the
  new set no longer declares its bucket, or when the bucket's initial value
  or `key` changed. Initial values are compared as compact JSON, so moving
  one between `json` and `jsonFile` is no change. A change of `newKey`
  keeps the copies, since their data stays valid.
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
JSON Pointer to the value, and exits with status 1. A valid directory
prints nothing, apart from [warnings](#warnings), and exits with status 0.
A directory that does not exist is an empty definition set, as for
`smock serve`, so it passes too; `smock check` then says on stderr that the
directory does not exist, so that a mistyped path is noticed. Give it the
`--template-env` that `smock serve` gets, with the same variables set, so
that it accepts the same [templates](#environment-variables).

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

A [CRUD Stub](#crud-stubs) matches by its method and path alone, in every
state. smock warns in three cases:

- an earlier CRUD Stub shadows a Stub whose `method` and exact `path` it
  serves, whatever that Stub's other conditions or `requires`. This
  catches an [override](#order-and-overrides) placed after the CRUD Stub
  instead of before it;
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

An OpenAPI document is turned into a Definition file by smock itself:
`smock import-openapi` writes a Stub for each documented response of each
operation, as [Importing OpenAPI](importing-openapi.md) explains.
