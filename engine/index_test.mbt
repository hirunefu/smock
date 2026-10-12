// Seam 1 tests of the edges of the match index. Each request is sent to an
// engine that finds Stubs through the index and to one that tries every
// Stub in matching order; they must agree on the whole outcome, and the
// winner must be the one the matching order gives.

///|
/// The ID of the Stub that answers each of `requests`, given as (method,
/// target, header fields), or `none`, one per line after the request. Fails
/// if the engines with and without the match index disagree on any part of
/// an outcome.
fn index_winners(
  files : Array[(String, String)],
  requests : Array[(String, String, Array[(String, String)])],
) -> String raise {
  let twins = twins(files)
  let lines = []
  for request in requests {
    let (meth, target, headers) = request
    let outcome = twins.send({ meth, target, headers, body: b"", })
    let shown_headers = headers.map(h => " [\{h.0}: \{h.1}]").join("")
    let winner = outcome.journal.stub.unwrap_or("none")
    lines.push("\{meth} \{target}\{shown_headers} -> \{winner}")
  }
  lines.join("\n")
}

///|
test "with the index, Stubs of equal priority are still tried in file-name order, indexed or not" {
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub(
          "a-pattern",
          priority=1,
          request="\"path\": { \"pattern\": \"/items/.*\" }",
        ),
      ]),
    ),
    (
      "b.json",
      stub_file([
        stub(
          "b-exact",
          priority=1,
          request="\"method\": \"GET\", \"path\": \"/items/1\"",
        ),
      ]),
    ),
    (
      "B.json",
      stub_file([
        stub(
          "B-exact",
          priority=1,
          request="\"method\": \"GET\", \"path\": \"/items/2\"",
        ),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/items/1", []),
      ("GET", "/items/2", []),
      ("POST", "/items/2", []),
      ("GET", "/items/3", []),
    ]),
    content=(
      #|GET /items/1 -> a-pattern
      #|GET /items/2 -> B-exact
      #|POST /items/2 -> a-pattern
      #|GET /items/3 -> a-pattern
    ),
  )
}

///|
test "with the index, Stubs without a priority still come after every Stub with one" {
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub("a-exact", request="\"method\": \"GET\", \"path\": \"/x\""),
        stub("a-any"),
      ]),
    ),
    (
      "b.json",
      stub_file([
        stub(
          "b-pattern",
          priority=100,
          request="\"path\": { \"pattern\": \"/[xy]\" }",
        ),
        stub("b-exact", priority=2147483647, request="\"path\": \"/z\""),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/x", []),
      ("GET", "/y", []),
      ("GET", "/z", []),
      ("GET", "/w", []),
    ]),
    content=(
      #|GET /x -> b-pattern
      #|GET /y -> b-pattern
      #|GET /z -> b-exact
      #|GET /w -> a-any
    ),
  )
}

///|
test "with the index, a repeated query parameter matches when any of its values does" {
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub(
          "tag-b",
          request="\"path\": \"/search\", \"query\": { \"tag\": \"b\" }",
        ),
        stub(
          "tag-number",
          request="\"path\": \"/search\", \"query\": { \"tag\": { \"pattern\": \"[0-9]+\" } }",
        ),
        stub("search", request="\"method\": \"GET\", \"path\": \"/search\""),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/search?tag=a&tag=b", []),
      ("GET", "/search?tag=b&tag=a", []),
      ("GET", "/search?tag=a&tag=7", []),
      ("GET", "/search?tag=a", []),
      ("POST", "/search?tag=a", []),
      ("GET", "/other?tag=b", []),
    ]),
    content=(
      #|GET /search?tag=a&tag=b -> tag-b
      #|GET /search?tag=b&tag=a -> tag-b
      #|GET /search?tag=a&tag=7 -> tag-number
      #|GET /search?tag=a -> search
      #|POST /search?tag=a -> none
      #|GET /other?tag=b -> none
    ),
  )
}

///|
test "with the index, header names are still compared in any case" {
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub(
          "exact-key",
          request="\"method\": \"GET\", \"path\": \"/x\", \"headers\": { \"X-Api-Key\": \"k1\" }",
        ),
        stub(
          "any-key",
          request="\"method\": \"GET\", \"path\": \"/x\", \"headers\": { \"x-api-key\": { \"pattern\": \"k[0-9]\" } }",
        ),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/x", [("x-api-key", "k1")]),
      ("GET", "/x", [("X-API-KEY", "k2")]),
      ("GET", "/x", [("X-Api-Key", "k3"), ("x-API-key", "k1")]),
      ("GET", "/x", [("X-Api-Key", "none")]),
    ]),
    content=(
      #|GET /x [x-api-key: k1] -> exact-key
      #|GET /x [X-API-KEY: k2] -> any-key
      #|GET /x [X-Api-Key: k3] [x-API-key: k1] -> exact-key
      #|GET /x [X-Api-Key: none] -> none
    ),
  )
}

///|
test "a Mock whose Stubs cannot be indexed is still answered in matching order" {
  // No Stub has a method or an exact path condition.
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub(
          "pattern",
          priority=1,
          request="\"path\": { \"pattern\": \"/a/.*\" }",
        ),
        stub("query", request="\"query\": { \"q\": \"1\" }"),
        stub("header", priority=0, request="\"headers\": { \"X-Id\": \"1\" }"),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/a/b", [("X-Id", "1")]),
      ("GET", "/a/b", []),
      ("POST", "/?q=1", []),
      ("GET", "/", []),
    ]),
    content=(
      #|GET /a/b [X-Id: 1] -> header
      #|GET /a/b -> pattern
      #|POST /?q=1 -> query
      #|GET / -> none
    ),
  )
}

///|
test "a Stub that cannot be indexed wins over an indexed Stub that comes later in matching order" {
  let files = [
    mock_m,
    (
      "a.json",
      stub_file([
        stub(
          "exact",
          priority=2,
          request="\"method\": \"GET\", \"path\": \"/users/1\"",
        ),
        stub(
          "pattern",
          priority=1,
          request="\"path\": { \"pattern\": \"/users/[0-9]+\" }",
        ),
        stub("exact-first", priority=0, request="\"path\": \"/users/2\""),
      ]),
    ),
  ]
  inspect(
    index_winners(files, [
      ("GET", "/users/1", []),
      ("GET", "/users/2", []),
      ("GET", "/users/x", []),
    ]),
    content=(
      #|GET /users/1 -> pattern
      #|GET /users/2 -> exact-first
      #|GET /users/x -> none
    ),
  )
}

///|
test "each snapshot is built with its own match index, and an engine keeps the one it was given" {
  let before = twins([
    mock_m,
    (
      "a.json",
      stub_file([
        stub("users", request="\"method\": \"GET\", \"path\": \"/users\""),
      ]),
    ),
  ])
  let after = twins([
    mock_m,
    (
      "a.json",
      stub_file([
        stub("users", request="\"method\": \"GET\", \"path\": \"/people\""),
      ]),
    ),
  ])
  let winner = (twins : Twins, target : String) => {
    twins.send({ meth: "GET", target, headers: [], body: b"", }).journal.stub
  }
  debug_inspect(
    [
      winner(before, "/users"),
      winner(before, "/people"),
      winner(after, "/users"),
      winner(after, "/people"),
    ],
    content="[Some(\"users\"), None, None, Some(\"users\")]",
  )
}
