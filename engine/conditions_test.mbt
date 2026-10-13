// Seam 1 tests of the exact and `json` request conditions: each condition
// on its own, with requests that meet it and requests that do not.

///|
/// A definition set of one Mock `m` whose Stubs are given as JSON objects,
/// in order. Each Stub answers 200 with its own ID as the body.
fn stubs(stubs : Array[String]) -> Harness {
  let out = StringBuilder()
  out.write_string("{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [")
  for i, stub in stubs {
    if i > 0 {
      out.write_string(",")
    }
    out.write_string(stub)
  }
  out.write_string("] }")
  harness([("m.json", out.to_string())])
}

///|
/// The ID of the Stub that answered each request, or `none`, one per line,
/// after the request.
fn winners(
  h : Harness,
  requests : Array[(String, String, Array[(String, String)], String)],
) -> String {
  requests
  .map(r => {
    let (meth, target, headers, body) = r
    let outcome = h.send(meth, target, headers~, body~)
    let winner = match matched_id(outcome) {
      Some(id) => id
      None => "none"
    }
    let shown_headers = headers.map(h => " [\{h.0}: \{h.1}]").join("")
    let shown_body = if body == "" { "" } else { " \{body.escape()}" }
    "\{meth} \{target}\{shown_headers}\{shown_body} -> \{winner}"
  })
  .join("\n")
}

///|
test "a Stub without conditions matches every request" {
  let h = stubs([
    (
      #|{ "id": "any", "mock": "m", "response": { "status": 200, "body": "any" } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [], ""),
      ("DELETE", "/users/1?x=y", [("X-A", "1")], "body"),
      ("PATCH", "*", [], "{}"),
    ]),
    content=(
      #|GET / -> any
      #|DELETE /users/1?x=y [X-A: 1] "body" -> any
      #|PATCH * "{}" -> any
    ),
  )
}

///|
test "the method is compared exactly, case and all" {
  let h = stubs([
    (
      #|{ "id": "get", "mock": "m", "request": { "method": "GET" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/a", [], ""),
      ("get", "/a", [], ""),
      ("GETX", "/a", [], ""),
      ("POST", "/a", [], ""),
    ]),
    content=(
      #|GET /a -> get
      #|get /a -> none
      #|GETX /a -> none
      #|POST /a -> none
    ),
  )
}

///|
test "the path is compared exactly with the percent-decoded path of the request, without its query" {
  let h = stubs([
    (
      #|{ "id": "space", "mock": "m", "request": { "path": "/users/a b" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "accent", "mock": "m", "request": { "path": "/café/100%" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "slash", "mock": "m", "request": { "path": "/a/b" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/users/a%20b", [], ""),
      ("GET", "/users/a%20b?q=1", [], ""),
      ("GET", "/users/a b", [], ""),
      ("GET", "/users/a+b", [], ""),
      ("GET", "/users/a%20b/", [], ""),
      ("GET", "/caf%C3%A9/100%25", [], ""),
      ("GET", "/caf%c3%a9/100%25", [], ""),
      ("GET", "/café/100%", [], ""),
      ("GET", "/a%2Fb", [], ""),
      ("GET", "/a/b", [], ""),
      ("GET", "/A/B", [], ""),
    ]),
    content=(
      #|GET /users/a%20b -> space
      #|GET /users/a%20b?q=1 -> space
      #|GET /users/a b -> space
      #|GET /users/a+b -> none
      #|GET /users/a%20b/ -> none
      #|GET /caf%C3%A9/100%25 -> accent
      #|GET /caf%c3%a9/100%25 -> accent
      #|GET /café/100% -> accent
      #|GET /a%2Fb -> slash
      #|GET /a/b -> slash
      #|GET /A/B -> none
    ),
  )
}

///|
test "a percent sign that does not start an escape stays as it is in the decoded path" {
  let h = stubs([
    (
      #|{ "id": "literal", "mock": "m", "request": { "path": "/100%/%zz/%4" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/100%/%zz/%4", [], ""),
      ("GET", "/100%25/%zz/%4", [], ""),
    ]),
    content=(
      #|GET /100%/%zz/%4 -> literal
      #|GET /100%25/%zz/%4 -> literal
    ),
  )
}

///|
test "the path and the query of an absolute-form target are decoded like those of an origin-form one" {
  let h = stubs([
    (
      #|{ "id": "search", "mock": "m",
      #|  "request": { "path": "/a b", "query": { "q": "x y" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "http://localhost:8080/a%20b?q=x+y", [], ""),
      ("GET", "http://localhost/a%20b?q=x%20y&other=1", [], ""),
      ("GET", "http://localhost/a%20b", [], ""),
    ]),
    content=(
      #|GET http://localhost:8080/a%20b?q=x+y -> search
      #|GET http://localhost/a%20b?q=x%20y&other=1 -> search
      #|GET http://localhost/a%20b -> none
    ),
  )
}

///|
test "each listed query parameter must be present with its decoded value; others are ignored" {
  let h = stubs([
    (
      #|{ "id": "search", "mock": "m",
      #|  "request": { "path": "/search", "query": { "q": "a b", "page": "2" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/search?q=a%20b&page=2", [], ""),
      ("GET", "/search?page=2&q=a+b", [], ""),
      ("GET", "/search?page=2&q=a+b&sort=asc&debug", [], ""),
      ("GET", "/search?%71=a%20b&p%61ge=%32", [], ""),
      ("GET", "/search?q=a%20b", [], ""),
      ("GET", "/search?q=a%20b&page=3", [], ""),
      ("GET", "/search?q=a%20b&page=2x", [], ""),
      ("GET", "/search?Q=a%20b&page=2", [], ""),
      ("GET", "/search?q=a%2Bb&page=2", [], ""),
      ("GET", "/search", [], ""),
    ]),
    content=(
      #|GET /search?q=a%20b&page=2 -> search
      #|GET /search?page=2&q=a+b -> search
      #|GET /search?page=2&q=a+b&sort=asc&debug -> search
      #|GET /search?%71=a%20b&p%61ge=%32 -> search
      #|GET /search?q=a%20b -> none
      #|GET /search?q=a%20b&page=3 -> none
      #|GET /search?q=a%20b&page=2x -> none
      #|GET /search?Q=a%20b&page=2 -> none
      #|GET /search?q=a%2Bb&page=2 -> none
      #|GET /search -> none
    ),
  )
}

///|
test "a repeated query parameter matches when any of its values does" {
  let h = stubs([
    (
      #|{ "id": "tagged", "mock": "m", "request": { "query": { "tag": "b" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?tag=a&tag=b&tag=c", [], ""),
      ("GET", "/?tag=b&tag=a", [], ""),
      ("GET", "/?tag=a&tag=c", [], ""),
      ("GET", "/?tag=a,b", [], ""),
    ]),
    content=(
      #|GET /?tag=a&tag=b&tag=c -> tagged
      #|GET /?tag=b&tag=a -> tagged
      #|GET /?tag=a&tag=c -> none
      #|GET /?tag=a,b -> none
    ),
  )
}

///|
test "a query parameter without = has the empty value" {
  let h = stubs([
    (
      #|{ "id": "flag", "mock": "m", "request": { "query": { "debug": "" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/?debug", [], ""),
      ("GET", "/?debug=", [], ""),
      ("GET", "/?x=1&&debug&", [], ""),
      ("GET", "/?debug=1", [], ""),
      ("GET", "/", [], ""),
      ("GET", "/?", [], ""),
    ]),
    content=(
      #|GET /?debug -> flag
      #|GET /?debug= -> flag
      #|GET /?x=1&&debug& -> flag
      #|GET /?debug=1 -> none
      #|GET / -> none
      #|GET /? -> none
    ),
  )
}

///|
test "each listed header must be present with its value, whatever the case of its name; others are ignored" {
  let h = stubs([
    (
      #|{ "id": "keyed", "mock": "m",
      #|  "request": { "headers": { "X-Api-Key": "s3cret", "accept": "application/json" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "GET",
        "/",
        [("X-Api-Key", "s3cret"), ("Accept", "application/json")],
        "",
      ),
      (
        "GET",
        "/",
        [
          ("Host", "localhost"),
          ("ACCEPT", "application/json"),
          ("x-api-key", "s3cret"),
          ("X-Other", "1"),
        ],
        "",
      ),
      ("GET", "/", [("X-Api-Key", "s3cret")], ""),
      (
        "GET",
        "/",
        [("X-Api-Key", "S3CRET"), ("Accept", "application/json")],
        "",
      ),
      (
        "GET",
        "/",
        [("X-Api-Key", "s3cret "), ("Accept", "application/json")],
        "",
      ),
      (
        "GET",
        "/",
        [("X-Api-Key", "s3cret"), ("Accept", "application/json, text/plain")],
        "",
      ),
      ("GET", "/?X-Api-Key=s3cret&accept=application/json", [], ""),
    ]),
    content=(
      #|GET / [X-Api-Key: s3cret] [Accept: application/json] -> keyed
      #|GET / [Host: localhost] [ACCEPT: application/json] [x-api-key: s3cret] [X-Other: 1] -> keyed
      #|GET / [X-Api-Key: s3cret] -> none
      #|GET / [X-Api-Key: S3CRET] [Accept: application/json] -> none
      #|GET / [X-Api-Key: s3cret ] [Accept: application/json] -> none
      #|GET / [X-Api-Key: s3cret] [Accept: application/json, text/plain] -> none
      #|GET /?X-Api-Key=s3cret&accept=application/json -> none
    ),
  )
}

///|
test "a repeated header matches when any of its values does, whatever the case of each name" {
  let h = stubs([
    (
      #|{ "id": "traced", "mock": "m", "request": { "headers": { "x-trace": "b" } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("X-Trace", "a"), ("x-TRACE", "b")], ""),
      ("GET", "/", [("X-TRACE", "b"), ("X-Trace", "a")], ""),
      ("GET", "/", [("X-Trace", "a"), ("X-Trace", "c")], ""),
    ]),
    content=(
      #|GET / [X-Trace: a] [x-TRACE: b] -> traced
      #|GET / [X-TRACE: b] [X-Trace: a] -> traced
      #|GET / [X-Trace: a] [X-Trace: c] -> none
    ),
  )
}

///|
test "each header field line is one value: a line that joins values with commas matches only as a whole" {
  let h = stubs([
    (
      #|{ "id": "tagged", "mock": "m", "request": { "headers": { "x-tag": "a" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "both", "mock": "m", "request": { "headers": { "x-tag": "b, a" } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "listed", "mock": "m",
      #|  "request": { "headers": { "x-tag": { "pattern": "(.*, )?a(, .*)?" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("GET", "/", [("X-Tag", "b"), ("X-Tag", "a")], ""),
      ("GET", "/", [("X-Tag", "b, a")], ""),
      ("GET", "/", [("X-Tag", "a, b")], ""),
      ("GET", "/", [("X-Tag", "ab, c")], ""),
    ]),
    content=(
      #|GET / [X-Tag: b] [X-Tag: a] -> tagged
      #|GET / [X-Tag: b, a] -> both
      #|GET / [X-Tag: a, b] -> listed
      #|GET / [X-Tag: ab, c] -> none
    ),
  )
}

///|
test "an exact body condition matches only a body of exactly that text in UTF-8" {
  let h = stubs([
    (
      #|{ "id": "exact", "mock": "m", "request": { "body": "name=Zoë\n" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "empty", "mock": "m", "request": { "method": "PUT", "body": "" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "name=Zoë\n"),
      ("POST", "/", [], "name=Zoë"),
      ("POST", "/", [], "name=Zoë\n "),
      ("POST", "/", [], "NAME=Zoë\n"),
      ("POST", "/", [], ""),
      ("PUT", "/", [], ""),
      ("PUT", "/", [], " "),
    ]),
    content=(
      #|POST / "name=Zoë\n" -> exact
      #|POST / "name=Zoë" -> none
      #|POST / "name=Zoë\n " -> none
      #|POST / "NAME=Zoë\n" -> none
      #|POST / -> none
      #|PUT / -> empty
      #|PUT / " " -> none
    ),
  )
}

///|
test "an exact body condition compares bytes, so a body that is not UTF-8 never matches it" {
  let h = stubs([
    (
      #|{ "id": "replacement", "mock": "m", "request": { "body": "�" },
      #|  "response": { "status": 200 } }
    ),
  ])
  let send = (body : Bytes) => {
    h.engine.handle(
      { meth: "POST", target: "/", version: "HTTP/1.1", headers: [], body, },
      session=None,
      now=h.now,
      rand=h.rand,
    )
    |> matched_id
  }
  debug_inspect(
    [send(b"\xff"), send(b"\xef\xbf\xbd")],
    content=(
      #|[None, Some("replacement")]
    ),
  )
}

///|
test "a json condition needs the listed object keys, matched recursively, and ignores other keys" {
  let h = stubs([
    (
      #|{ "id": "alice", "mock": "m",
      #|  "request": { "body": { "json": {
      #|    "name": "Alice",
      #|    "address": { "city": "Paris", "geo": { "lat": 48.85 } } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/",
        [],
        "{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{\"lat\":48.85}}}",
      ),
      (
        "POST",
        "/",
        [],
        "{ \"id\": 1, \"address\": { \"zip\": \"75001\", \"geo\": { \"lng\": 2.35, \"lat\": 48.85 }, \"city\": \"Paris\" }, \"name\": \"Alice\" }",
      ),
      (
        "POST",
        "/",
        [],
        "{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{}}}",
      ),
      (
        "POST",
        "/",
        [],
        "{\"name\":\"Alice\",\"address\":{\"city\":\"Lyon\",\"geo\":{\"lat\":48.85}}}",
      ),
      ("POST", "/", [], "{\"name\":\"Alice\",\"address\":\"Paris\"}"),
      ("POST", "/", [], "{\"name\":\"Alice\"}"),
      (
        "POST",
        "/",
        [],
        "[{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{\"lat\":48.85}}}]",
      ),
    ]),
    content=(
      #|POST / "{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{\"lat\":48.85}}}" -> alice
      #|POST / "{ \"id\": 1, \"address\": { \"zip\": \"75001\", \"geo\": { \"lng\": 2.35, \"lat\": 48.85 }, \"city\": \"Paris\" }, \"name\": \"Alice\" }" -> alice
      #|POST / "{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{}}}" -> none
      #|POST / "{\"name\":\"Alice\",\"address\":{\"city\":\"Lyon\",\"geo\":{\"lat\":48.85}}}" -> none
      #|POST / "{\"name\":\"Alice\",\"address\":\"Paris\"}" -> none
      #|POST / "{\"name\":\"Alice\"}" -> none
      #|POST / "[{\"name\":\"Alice\",\"address\":{\"city\":\"Paris\",\"geo\":{\"lat\":48.85}}}]" -> none
    ),
  )
}

///|
test "a json condition needs arrays of the same length, matched element by element" {
  let h = stubs([
    (
      #|{ "id": "tags", "mock": "m",
      #|  "request": { "body": { "json": { "tags": ["a", { "k": 1 }, []] } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "{\"tags\":[\"a\",{\"k\":1},[]]}"),
      ("POST", "/", [], "{\"tags\":[\"a\",{\"k\":1,\"x\":2},[]]}"),
      ("POST", "/", [], "{\"tags\":[\"a\",{\"k\":1}]}"),
      ("POST", "/", [], "{\"tags\":[\"a\",{\"k\":1},[],\"b\"]}"),
      ("POST", "/", [], "{\"tags\":[{\"k\":1},\"a\",[]]}"),
      ("POST", "/", [], "{\"tags\":[\"a\",{\"k\":1},[0]]}"),
      ("POST", "/", [], "{\"tags\":\"a\"}"),
    ]),
    content=(
      #|POST / "{\"tags\":[\"a\",{\"k\":1},[]]}" -> tags
      #|POST / "{\"tags\":[\"a\",{\"k\":1,\"x\":2},[]]}" -> tags
      #|POST / "{\"tags\":[\"a\",{\"k\":1}]}" -> none
      #|POST / "{\"tags\":[\"a\",{\"k\":1},[],\"b\"]}" -> none
      #|POST / "{\"tags\":[{\"k\":1},\"a\",[]]}" -> none
      #|POST / "{\"tags\":[\"a\",{\"k\":1},[0]]}" -> none
      #|POST / "{\"tags\":\"a\"}" -> none
    ),
  )
}

///|
test "a json condition needs scalars to be equal: same type, and numbers by value" {
  let h = stubs([
    (
      #|{ "id": "scalars", "mock": "m",
      #|  "request": { "body": { "json": { "n": 1, "s": "1", "t": true, "z": null } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "{\"n\":1,\"s\":\"1\",\"t\":true,\"z\":null}"),
      ("POST", "/", [], "{\"n\":1.0,\"s\":\"1\",\"t\":true,\"z\":null}"),
      ("POST", "/", [], "{\"n\":1e0,\"s\":\"1\",\"t\":true,\"z\":null}"),
      ("POST", "/", [], "{\"n\":\"1\",\"s\":\"1\",\"t\":true,\"z\":null}"),
      ("POST", "/", [], "{\"n\":1,\"s\":1,\"t\":true,\"z\":null}"),
      ("POST", "/", [], "{\"n\":1,\"s\":\"1\",\"t\":1,\"z\":null}"),
      ("POST", "/", [], "{\"n\":1,\"s\":\"1\",\"t\":true,\"z\":false}"),
      ("POST", "/", [], "{\"n\":1,\"s\":\"1\",\"t\":true}"),
      ("POST", "/", [], "{\"n\":1.5,\"s\":\"1\",\"t\":true,\"z\":null}"),
    ]),
    content=(
      #|POST / "{\"n\":1,\"s\":\"1\",\"t\":true,\"z\":null}" -> scalars
      #|POST / "{\"n\":1.0,\"s\":\"1\",\"t\":true,\"z\":null}" -> scalars
      #|POST / "{\"n\":1e0,\"s\":\"1\",\"t\":true,\"z\":null}" -> scalars
      #|POST / "{\"n\":\"1\",\"s\":\"1\",\"t\":true,\"z\":null}" -> none
      #|POST / "{\"n\":1,\"s\":1,\"t\":true,\"z\":null}" -> none
      #|POST / "{\"n\":1,\"s\":\"1\",\"t\":1,\"z\":null}" -> none
      #|POST / "{\"n\":1,\"s\":\"1\",\"t\":true,\"z\":false}" -> none
      #|POST / "{\"n\":1,\"s\":\"1\",\"t\":true}" -> none
      #|POST / "{\"n\":1.5,\"s\":\"1\",\"t\":true,\"z\":null}" -> none
    ),
  )
}

///|
test "a json condition compares numbers by their exact value, even integers above 2^53 and numbers beyond a Double's range" {
  let h = stubs([
    (
      #|{ "id": "id", "mock": "m",
      #|  "request": { "body": { "json": { "id": 9007199254740993 } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "huge", "mock": "m",
      #|  "request": { "body": { "json": { "v": 1e400 } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "{\"id\":9007199254740993}"),
      ("POST", "/", [], "{\"id\":9007199254740992}"),
      ("POST", "/", [], "{\"id\":9007199254740994}"),
      ("POST", "/", [], "{\"v\":1e400}"),
      ("POST", "/", [], "{\"v\":10E+399}"),
      ("POST", "/", [], "{\"v\":1e401}"),
      ("POST", "/", [], "{\"v\":-1e400}"),
    ]),
    content=(
      #|POST / "{\"id\":9007199254740993}" -> id
      #|POST / "{\"id\":9007199254740992}" -> none
      #|POST / "{\"id\":9007199254740994}" -> none
      #|POST / "{\"v\":1e400}" -> huge
      #|POST / "{\"v\":10E+399}" -> huge
      #|POST / "{\"v\":1e401}" -> none
      #|POST / "{\"v\":-1e400}" -> none
    ),
  )
}

///|
test "a json condition fails on a body that does not parse as JSON" {
  let h = stubs([
    (
      #|{ "id": "object", "mock": "m", "request": { "body": { "json": {} } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "number", "mock": "m", "request": { "body": { "json": 42 } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "{}"),
      ("POST", "/", [], " {\"any\": [1]}\n"),
      ("POST", "/", [], "42"),
      ("POST", "/", [], ""),
      ("POST", "/", [], "{"),
      ("POST", "/", [], "{} {}"),
      ("POST", "/", [], "{'a': 1}"),
      ("POST", "/", [], "[]"),
      ("POST", "/", [], "\"{}\""),
    ]),
    content=(
      #|POST / "{}" -> object
      #|POST / " {\"any\": [1]}\n" -> object
      #|POST / "42" -> number
      #|POST / -> none
      #|POST / "{" -> none
      #|POST / "{} {}" -> none
      #|POST / "{'a': 1}" -> none
      #|POST / "[]" -> none
      #|POST / "\"{}\"" -> none
    ),
  )
  let send = (body : Bytes) => {
    h.engine.handle(
      { meth: "POST", target: "/", version: "HTTP/1.1", headers: [], body, },
      session=None,
      now=h.now,
      rand=h.rand,
    )
    |> matched_id
  }
  // Not UTF-8: not JSON.
  debug_inspect(send(b"{\"a\":\"\xff\"}"), content="None")
}

///|
test "a json condition from a YAML file means what it means in JSON" {
  let h = harness([
    (
      "m.yaml",
      (
        #|mocks: [{ name: m }]
        #|stubs:
        #|  - id: yaml
        #|    mock: m
        #|    request:
        #|      body:
        #|        json:
        #|          name: Alice
        #|          age: 30
        #|          tags: [a, "1"]
        #|    response: { status: 200 }
      ),
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/",
        [],
        "{\"age\":30,\"name\":\"Alice\",\"tags\":[\"a\",\"1\"]}",
      ),
      (
        "POST",
        "/",
        [],
        "{\"age\":\"30\",\"name\":\"Alice\",\"tags\":[\"a\",\"1\"]}",
      ),
      ("POST", "/", [], "{\"age\":30,\"name\":\"Alice\",\"tags\":[\"a\",1]}"),
    ]),
    content=(
      #|POST / "{\"age\":30,\"name\":\"Alice\",\"tags\":[\"a\",\"1\"]}" -> yaml
      #|POST / "{\"age\":\"30\",\"name\":\"Alice\",\"tags\":[\"a\",\"1\"]}" -> none
      #|POST / "{\"age\":30,\"name\":\"Alice\",\"tags\":[\"a\",1]}" -> none
    ),
  )
}
