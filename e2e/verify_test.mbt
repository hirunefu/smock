// Seam 2 tests of verification and the unmatched requests: real requests
// sent to the running smock, then checked over the authenticated Admin API,
// for the calling Session. Every Admin API response is checked against the
// OpenAPI document (contract_test.mbt).

///|
/// Sends `GET <target>` to the Mock `users` of `journal_defs`, as
/// `session`.
async fn Smock::get_user(
  self : Smock,
  target : String,
  session : String,
) -> Unit {
  let _ = self.request("GET", target, headers=[
    ("Host", "localhost"),
    baggage(session),
  ])
}

///|
async test "verify counts the calling Session's requests that pass the filter, and checks the count exactly, at least or at most N" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      for target in ["/users/1", "/users/2", "/users/1"] {
        smock.get_user(target, "counted")
      }
      // Another Session's request is never counted.
      smock.get_user("/users/1", "other")
      let filter = "{\"method\":\"GET\",\"path\":\"/users/1\"}"
      let out = []
      for
        check in [
          "\"exactly\":2", "\"exactly\":3", "\"atLeast\":2", "\"atLeast\":3", "\"atMost\":1",
          "\"atMost\":2",
        ] {
        let verdict = smock.call(
          "POST",
          "/v1/journal/verify",
          session="counted",
          body="{\"filter\":\{filter},\{check}}",
        )
        out.push("\{check}: \{verdict}")
      }
      let verdict = smock.call(
        "POST",
        "/v1/journal/verify",
        body="{\"filter\":\{filter},\"exactly\":0}",
      )
      out.push("no Session, \"exactly\":0: \{verdict}")
      inspect(
        out.join("\n"),
        content=(
          #|"exactly":2: 200 {"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
          #|"exactly":3: 200 {"ok":false,"count":2,"evicted":0,"reason":"count","warnings":[]}
          #|"atLeast":2: 200 {"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
          #|"atLeast":3: 200 {"ok":false,"count":2,"evicted":0,"reason":"count","warnings":[]}
          #|"atMost":1: 200 {"ok":false,"count":2,"evicted":0,"reason":"count","warnings":[]}
          #|"atMost":2: 200 {"ok":true,"count":2,"evicted":0,"reason":null,"warnings":[]}
          #|no Session, "exactly":0: 200 {"ok":true,"count":0,"evicted":0,"reason":null,"warnings":[]}
        ),
      )
    })
  })
}

///|
async test "after the bound evicts a Session's requests, at most 0 fails with reason evicted, while at least is still decided by the count" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--journal-max-entries", "10"],
      smock => {
        for _ in 0..<2 {
          smock.get_user("/users/1", "test-a")
        }
        for _ in 0..<10 {
          smock.get_user("/users/2", "test-b")
        }
        let filter = "{\"method\":\"GET\",\"path\":\"/users/1\"}"
        let out = []
        for check in ["\"atMost\":0", "\"atLeast\":0", "\"atLeast\":1"] {
          let verdict = smock.call(
            "POST",
            "/v1/journal/verify",
            session="test-a",
            body="{\"filter\":\{filter},\{check}}",
          )
          out.push("\{check}: \{verdict}")
        }
        inspect(
          out.join("\n"),
          content=(
            #|"atMost":0: 200 {"ok":false,"count":0,"evicted":2,"reason":"evicted","warnings":[]}
            #|"atLeast":0: 200 {"ok":true,"count":0,"evicted":2,"reason":null,"warnings":[]}
            #|"atLeast":1: 200 {"ok":false,"count":0,"evicted":2,"reason":"count","warnings":[]}
          ),
        )
      },
    )
  })
}

///|
async test "verify and the unmatched requests need the bearer token" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for
      call in [
        ("POST", "/v1/journal/verify", Some("{\"exactly\":0}")),
        ("GET", "/v1/journal/unmatched", None),
      ] {
      let (meth, path, body) = call
      let response = smock.admin(meth, path, token=None, body?)
      out.push("\{meth} \{path}: \{response.status} \{response.body}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|POST /v1/journal/verify: 401 {"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
        #|GET /v1/journal/unmatched: 401 {"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
      ),
    )
  })
}

///|
async test "a verification that does not have the shape of the document is refused with invalid_request, naming every problem" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for
      body in [
        None,
        Some("[]"),
        Some("{\"filter\":{\"path\":\"/users/1\"}}"),
        Some("{\"count\":{\"exactly\":1}}"),
        Some("{\"exactly\":1,\"atMost\":-1,\"filter\":{\"since\":\"now\"}}"),
      ] {
      let response = smock.admin("POST", "/v1/journal/verify", body?)
      out.push("\{response.status} \{response.body}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|400 {"error":"invalid_request","message":"the body must be a verification: a JSON object, such as {\"filter\":{\"path\":\"/users/1\"},\"exactly\":1}","warnings":[]}
        #|400 {"error":"invalid_request","message":"the verification is not valid: must be an object","warnings":[]}
        #|400 {"error":"invalid_request","message":"the verification is not valid: must have exactly one of exactly, atLeast and atMost","warnings":[]}
        #|400 {"error":"invalid_request","message":"the verification is not valid: must have exactly one of exactly, atLeast and atMost\n/count: is not a known field","warnings":[]}
        #|400 {"error":"invalid_request","message":"the verification is not valid: must have exactly one of exactly, atLeast and atMost\n/atMost: must be an integer of 0 or more\n/filter/since: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z","warnings":[]}
      ),
    )
  })
}

///|
async test "verification whose filter names a Mock whose Journal is off, or while the Journal is off globally, gets journal_off; so do the unmatched requests while it is off globally" {
  with_definitions([("users.json", journal_defs)], dir => {
    let out = []
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      out.push(
        "orders: " +
        smock.call(
          "POST",
          "/v1/journal/verify",
          session="s",
          body="{\"filter\":{\"mock\":\"orders\"},\"exactly\":0}",
        ),
      )
      out.push(
        "users: " +
        smock.call(
          "POST",
          "/v1/journal/verify",
          session="s",
          body="{\"filter\":{\"mock\":\"users\"},\"exactly\":0}",
        ),
      )
    })
    let _ = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_JOURNAL": "off" },
      smock => {
        smock.get_user("/users/1", "s")
        out.push(
          "--journal off, verify: " +
          smock.call(
            "POST",
            "/v1/journal/verify",
            session="s",
            body="{\"exactly\":0}",
          ),
        )
        out.push(
          "--journal off, unmatched: " +
          smock.call("GET", "/v1/journal/unmatched", session="s"),
        )
      },
    )
    inspect(
      out.join("\n"),
      content=(
        #|orders: 409 {"error":"journal_off","message":"the Journal is off for the Mock \"orders\" (\"journal\": false in the Definition files): smock records none of its requests","warnings":[]}
        #|users: 200 {"ok":true,"count":0,"evicted":0,"reason":null,"warnings":[]}
        #|--journal off, verify: 409 {"error":"journal_off","message":"the Journal is off (--journal off): smock records no request","warnings":[]}
        #|--journal off, unmatched: 409 {"error":"journal_off","message":"the Journal is off (--journal off): smock records no request","warnings":[]}
      ),
    )
  })
}

///|
/// The unmatched requests of `session`, at most `limit` of them when it is
/// given, checked against the document: the status and the body.
async fn Smock::unmatched(
  self : Smock,
  session : String,
  limit? : String,
) -> (Int, Json) {
  let path = match limit {
    Some(limit) => "/v1/journal/unmatched?limit=\{limit}"
    None => "/v1/journal/unmatched"
  }
  let response = self.admin("GET", path, headers=[baggage(session)])
  (response.status, response.json())
}

///|
async test "the unmatched requests list the calling Session's requests that no Stub answered, oldest first, each with its full Near miss, and an unknown Host with no Mock" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("unmatched")
      let _ = smock.request("POST", "/users/1", body="hello", headers=[
        ("Host", "users.example.com"),
        session,
      ])
      // Answered by a Stub: not listed.
      let _ = smock.request("GET", "/users/1", headers=[
        ("Host", "users.example.com"),
        session,
      ])
      let _ = smock.request("GET", "/users/x", headers=[
        ("Host", "nowhere.example.com"),
        session,
      ])
      // Another Session's unmatched request: not listed.
      let _ = smock.request("POST", "/users/1", headers=[
        ("Host", "users.example.com"),
        baggage("other"),
      ])
      let (status, page) = smock.unmatched("unmatched")
      inspect(status, content="200")
      json_inspect(journal_shown(page), content={
        "entries": [
          {
            "seq": 1,
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "unmatched",
            "host": "users.example.com",
            "mock": "users",
            "viaDefault": false,
            "digest": "<digest>",
            "request": {
              "method": "POST",
              "target": "/users/1",
              "version": "HTTP/1.1",
              "headers": [
                { "name": "Host", "value": "users.example.com" },
                {
                  "name": "baggage",
                  "value": "userId=alice,smock-session=unmatched;ttl=60",
                },
                { "name": "Content-Length", "value": "5" },
              ],
              "body": {
                "encoding": "utf-8",
                "data": "hello",
                "size": 5,
                "truncated": false,
              },
            },
            "stub": Json::null(),
            "stubSource": Json::null(),
            "nearMiss": {
              "stub": "get-user",
              "stubSource": "file",
              "failed": [
                { "condition": "method", "expected": "GET", "actual": ["POST"] },
              ],
            },
            "status": 404,
            "fault": Json::null(),
          },
          {
            "seq": 3,
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "unmatched",
            "host": "nowhere.example.com",
            "mock": Json::null(),
            "viaDefault": false,
            "digest": "<digest>",
            "request": {
              "method": "GET",
              "target": "/users/x",
              "version": "HTTP/1.1",
              "headers": [
                { "name": "Host", "value": "nowhere.example.com" },
                {
                  "name": "baggage",
                  "value": "userId=alice,smock-session=unmatched;ttl=60",
                },
                { "name": "Content-Length", "value": "0" },
              ],
              "body": {
                "encoding": "utf-8",
                "data": "",
                "size": 0,
                "truncated": false,
              },
            },
            "stub": Json::null(),
            "stubSource": Json::null(),
            "nearMiss": Json::null(),
            "status": 404,
            "fault": Json::null(),
          },
        ],
        "more": false,
        "evicted": 0,
        "warnings": [],
      })
    })
  })
}

///|
async test "the unmatched requests come at most limit at a time; a limit that is not an integer from 1 to 10000 is refused with invalid_request" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      for target in ["/nope/1", "/nope/2", "/nope/3"] {
        smock.get_user(target, "paged")
      }
      let out = []
      for
        limit in [
          "2", "3", "10000", "0", "10001", "x", "-1", "%31", "1&limit=2", "",
        ] {
        let shown = match smock.unmatched("paged", limit~) {
          (200, Object({ "entries": Array(entries), "more": more, .. })) => {
            let targets = entries.map(entry => {
              guard entry
                is Object(
                  { "request": Object({ "target": String(target), .. }), .. }
                ) else {
                return "?"
              }
              target
            })
            "200 \{targets.join(", ")}, more: \{more.stringify()}"
          }
          (status, body) => "\{status} \{body.stringify()}"
        }
        out.push("limit=\{limit}: \{shown}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|limit=2: 200 /nope/1, /nope/2, more: true
          #|limit=3: 200 /nope/1, /nope/2, /nope/3, more: false
          #|limit=10000: 200 /nope/1, /nope/2, /nope/3, more: false
          #|limit=0: 400 {"error":"invalid_request","message":"the limit query parameter must be an integer from 1 to 10000","warnings":[]}
          #|limit=10001: 400 {"error":"invalid_request","message":"the limit query parameter must be an integer from 1 to 10000","warnings":[]}
          #|limit=x: 400 {"error":"invalid_request","message":"the limit query parameter must be an integer from 1 to 10000","warnings":[]}
          #|limit=-1: 400 {"error":"invalid_request","message":"the limit query parameter must be an integer from 1 to 10000","warnings":[]}
          #|limit=%31: 200 /nope/1, more: true
          #|limit=1&limit=2: 400 {"error":"invalid_request","message":"the limit query parameter is given more than once","warnings":[]}
          #|limit=: 400 {"error":"invalid_request","message":"the limit query parameter must be an integer from 1 to 10000","warnings":[]}
        ),
      )
    })
  })
}

///|
/// The entries of a Journal page, `body`, as their sequence numbers and
/// targets, then `more`; or the status and body of a refusal.
fn page_of(status : Int, body : Json) -> String {
  guard status == 200 &&
    body is Object({ "entries": Array(entries), "more": more, .. }) else {
    return "\{status} \{body.stringify()}"
  }
  let shown = entries.map(entry => {
    guard entry
      is Object(
        {
          "seq": Number(seq, ..),
          "request": Object({ "target": String(target), .. }),
          ..
        }
      ) else {
      return "?"
    }
    "\{seq.to_int64()} \{target}"
  })
  let shown = if shown.is_empty() { "none" } else { shown.join(", ") }
  "\{shown}, more: \{more.stringify()}"
}

///|
async test "a query and the unmatched requests page after the last entry of the page before; an after that is not an integer from 0 to 2^53 - 1 is refused with invalid_request" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      for target in ["/nope/1", "/users/1", "/nope/2", "/nope/3"] {
        smock.get_user(target, "paged")
      }
      let out = []
      for after in ["", "&after=0", "&after=1", "&after=3", "&after=4"] {
        let (status, body) = smock.unmatched("paged", limit="2\{after}")
        out.push("unmatched, limit=2\{after}: \{page_of(status, body)}")
      }
      for after in ["", ",\"after\":2"] {
        let response = smock.admin(
          "POST",
          "/v1/journal/query",
          headers=[baggage("paged")],
          body="{\"limit\":2\{after}}",
        )
        out.push(
          "query {\"limit\":2\{after}}: \{page_of(response.status, response.json())}",
        )
      }
      for after in ["-1", "x", "1.5", "9007199254740992", "", "1&after=2"] {
        let (status, body) = smock.unmatched("paged", limit="2&after=\{after}")
        out.push("after=\{after}: \{page_of(status, body)}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|unmatched, limit=2: 1 /nope/1, 3 /nope/2, more: true
          #|unmatched, limit=2&after=0: 1 /nope/1, 3 /nope/2, more: true
          #|unmatched, limit=2&after=1: 3 /nope/2, 4 /nope/3, more: false
          #|unmatched, limit=2&after=3: 4 /nope/3, more: false
          #|unmatched, limit=2&after=4: none, more: false
          #|query {"limit":2}: 1 /nope/1, 2 /users/1, more: true
          #|query {"limit":2,"after":2}: 3 /nope/2, 4 /nope/3, more: false
          #|after=-1: 400 {"error":"invalid_request","message":"the after query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
          #|after=x: 400 {"error":"invalid_request","message":"the after query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
          #|after=1.5: 400 {"error":"invalid_request","message":"the after query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
          #|after=9007199254740992: 400 {"error":"invalid_request","message":"the after query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
          #|after=: 400 {"error":"invalid_request","message":"the after query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
          #|after=1&after=2: 400 {"error":"invalid_request","message":"the after query parameter is given more than once","warnings":[]}
        ),
      )
    })
  })
}
