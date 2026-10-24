// Seam 1 tests of verification: counting the calling Session's Journal
// entries that pass the shared filter, and checking the count exactly, at
// least or at most N, without trusting a count that eviction may have
// lowered.

///|
/// Verifies the Journal of `session` with the request given as JSON text,
/// the `VerifyRequest` schema, and returns the verdict as JSON, or the
/// error.
fn Harness::verify(
  self : Harness,
  session : String?,
  request : String,
) -> Json raise {
  let request = @engine.VerifyRequest::from_json(@json.parse(request))
  let verification = self.engine.verify(request, session~) catch {
    err => return Json::string("refused: \{@debug.to_string(err)}")
  }
  ToJson::to_json(verification)
}

///|
test "after the bound evicts a Session's entries, at most 0 fails with reason evicted instead of passing with a count of 0" {
  // The Journal walkthrough of the state-model prototype: test-b's requests
  // push test-a's two out of a Journal of ten entries.
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=10),
  )
  for _ in 0..<2 {
    let _ = h.record("GET", "/users/1", session="test-a")
  }
  for _ in 0..<10 {
    let _ = h.record("GET", "/users/2", session="test-b")
  }
  json_inspect(
    h.verify(
      Some("test-a"),
      "{ \"filter\": { \"method\": \"GET\", \"path\": \"/users/1\" }, \"atMost\": 0 }",
    ),
    content={ "ok": false, "count": 0, "evicted": 2, "reason": "evicted" },
  )
}

///|
/// The verdicts of each check in `checks`, such as `"atMost": 0`, of the
/// entries of `session` that pass `filter`, one per line.
fn Harness::verdicts(
  self : Harness,
  session : String?,
  checks : Array[String],
  filter~ : String = "{}",
) -> String raise {
  checks
  .map(check => {
    let verdict = self.verify(session, "{ \"filter\": \{filter}, \{check} }")
    "\{check} -> \{verdict.stringify()}"
  })
  .join("\n")
}

///|
test "exactly, at least and at most N check the count of the entries that pass the filter" {
  let h = harness([("users.json", journal_users)])
  let _ = h.record("GET", "/users/1", session="test-a")
  let _ = h.record("POST", "/users", session="test-a")
  let _ = h.record("GET", "/users/1", session="test-a")
  inspect(
    h.verdicts(
      Some("test-a"),
      [
        "\"exactly\": 1", "\"exactly\": 2", "\"exactly\": 3", "\"atLeast\": 0", "\"atLeast\": 2",
        "\"atLeast\": 3", "\"atMost\": 1", "\"atMost\": 2", "\"atMost\": 3",
      ],
      filter="{ \"method\": \"GET\", \"path\": \"/users/1\" }",
    ),
    content=(
      #|"exactly": 1 -> {"ok":false,"count":2,"evicted":0,"reason":"count"}
      #|"exactly": 2 -> {"ok":true,"count":2,"evicted":0,"reason":null}
      #|"exactly": 3 -> {"ok":false,"count":2,"evicted":0,"reason":"count"}
      #|"atLeast": 0 -> {"ok":true,"count":2,"evicted":0,"reason":null}
      #|"atLeast": 2 -> {"ok":true,"count":2,"evicted":0,"reason":null}
      #|"atLeast": 3 -> {"ok":false,"count":2,"evicted":0,"reason":"count"}
      #|"atMost": 1 -> {"ok":false,"count":2,"evicted":0,"reason":"count"}
      #|"atMost": 2 -> {"ok":true,"count":2,"evicted":0,"reason":null}
      #|"atMost": 3 -> {"ok":true,"count":2,"evicted":0,"reason":null}
    ),
  )
}

///|
test "once a Session's entries were evicted, exactly and at most fail with reason evicted whatever the count, and at least is still decided by the count" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=3),
  )
  // The bound evicts the first of these four.
  for _ in 0..<4 {
    let _ = h.record("GET", "/users/1", session="test-a")
  }
  inspect(
    h.verdicts(Some("test-a"), [
      "\"exactly\": 3", "\"exactly\": 4", "\"atMost\": 3", "\"atMost\": 100", "\"atLeast\": 3",
      "\"atLeast\": 4",
    ]),
    content=(
      #|"exactly": 3 -> {"ok":false,"count":3,"evicted":1,"reason":"evicted"}
      #|"exactly": 4 -> {"ok":false,"count":3,"evicted":1,"reason":"evicted"}
      #|"atMost": 3 -> {"ok":false,"count":3,"evicted":1,"reason":"evicted"}
      #|"atMost": 100 -> {"ok":false,"count":3,"evicted":1,"reason":"evicted"}
      #|"atLeast": 3 -> {"ok":true,"count":3,"evicted":1,"reason":null}
      #|"atLeast": 4 -> {"ok":false,"count":3,"evicted":1,"reason":"count"}
    ),
  )
}

///|
test "verification counts only the calling Session's entries, and only that Session's evictions spoil its count; requests without a Session form their own space" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=4),
  )
  // The bound evicts test-b's first two entries.
  for session in [Some("test-b"), Some("test-b"), Some("test-a"), None] {
    let _ = h.record("GET", "/users/1", session?)
  }
  for _ in 0..<2 {
    let _ = h.record("GET", "/users/1", session="test-b")
  }
  let out = []
  for
    case in [
      (Some("test-a"), 1),
      (Some("test-b"), 2),
      (None, 1),
      (Some("test-c"), 0),
    ] {
    let (session, n) = case
    let check = "\"exactly\": \{n}"
    let name = session.unwrap_or("no Session")
    out.push("\{name}: \{h.verdicts(session, [check])}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|test-a: "exactly": 1 -> {"ok":true,"count":1,"evicted":0,"reason":null}
      #|test-b: "exactly": 2 -> {"ok":false,"count":2,"evicted":2,"reason":"evicted"}
      #|no Session: "exactly": 1 -> {"ok":true,"count":1,"evicted":0,"reason":null}
      #|test-c: "exactly": 0 -> {"ok":true,"count":0,"evicted":0,"reason":null}
    ),
  )
}

///|
test "a Session reset clears its eviction count, so that at most is trusted again" {
  let h = harness(
    [("users.json", journal_users)],
    journal=@engine.JournalSettings(max_entries=1),
  )
  for _ in 0..<2 {
    let _ = h.record("GET", "/users/1", session="test-a")
  }
  let before = h.verdicts(Some("test-a"), ["\"atMost\": 1"])
  let _ = h.engine.reset(Session(Some("test-a")))
  let after = h.verdicts(Some("test-a"), ["\"atMost\": 1"])
  inspect(
    "before the reset: \{before}\nafter it: \{after}",
    content=(
      #|before the reset: "atMost": 1 -> {"ok":false,"count":1,"evicted":1,"reason":"evicted"}
      #|after it: "atMost": 1 -> {"ok":true,"count":0,"evicted":0,"reason":null}
    ),
  )
}

///|
test "verification whose filter names a Mock whose Journal is off, or while the Journal is off globally, is refused instead of counting" {
  let shop = [
    ("users.json", journal_users),
    (
      "orders.json",
      (
        #|{ "mocks": [{ "name": "orders", "hosts": ["orders.example.com"], "journal": false }] }
      ),
    ),
  ]
  let h = harness(shop)
  let _ = h.record("GET", "http://orders.example.com/orders/1", session="s")
  let _ = h.record("GET", "/users/1", session="s")
  let off = harness(shop, journal=@engine.JournalSettings(enabled=false))
  let _ = off.record("GET", "/users/1", session="s")
  let verify = (h : Harness, filter : String) => {
    h.verify(Some("s"), "{ \"filter\": \{filter}, \"atLeast\": 0 }").stringify()
  }
  inspect(
    [
      "orders: \{verify(h, "{ \"mock\": \"orders\" }")}",
      "users: \{verify(h, "{ \"mock\": \"users\" }")}",
      "any Mock: \{verify(h, "{}")}",
      "--journal off: \{verify(off, "{}")}",
      "--journal off, users: \{verify(off, "{ \"mock\": \"users\" }")}",
    ].join("\n"),
    content=(
      #|orders: "refused: JournalOff(Some(\"orders\"))"
      #|users: {"ok":true,"count":1,"evicted":0,"reason":null}
      #|any Mock: {"ok":true,"count":1,"evicted":0,"reason":null}
      #|--journal off: "refused: JournalOff(None)"
      #|--journal off, users: "refused: JournalOff(None)"
    ),
  )
}

///|
test "a verification that does not have the shape of the Admin API document is rejected with every problem and where it is" {
  let requests = [
    "[]", "{}", "{ \"filter\": { \"path\": \"/users/1\" } }", "{ \"exactly\": 1, \"atMost\": 2 }",
    "{ \"count\": { \"exactly\": 1 } }", "{ \"exactly\": -1 }", "{ \"atLeast\": 1.5 }",
    "{ \"atMost\": \"2\" }", "{ \"exactly\": null }", "{ \"atLeast\": 1, \"filter\": { \"path\": \"users\", \"since\": 1 } }",
    "{ \"atMost\": 0, \"limit\": 10 }", "{ \"exactly\": 0 }", "{ \"atMost\": 1e12, \"filter\": {} }",
  ]
  let out = []
  for request in requests {
    let result = try
      @engine.VerifyRequest::from_json(@json.parse(request)) |> Ok
    catch {
      err => Err(err)
    }
    match result {
      Ok(parsed) => out.push("\{request}: \{@debug.to_string(parsed.check)}")
      Err(err) => {
        let message = match err {
          @engine.InvalidQuery(_) as err => err.message()
          err => "unexpected: \{err}"
        }
        out.push("\{request}:\n  \{message.replace_all(old="\n", new="\n  ")}")
      }
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|[]:
      #|  must be an object
      #|{}:
      #|  must have exactly one of exactly, atLeast and atMost
      #|{ "filter": { "path": "/users/1" } }:
      #|  must have exactly one of exactly, atLeast and atMost
      #|{ "exactly": 1, "atMost": 2 }:
      #|  must have exactly one of exactly, atLeast and atMost
      #|{ "count": { "exactly": 1 } }:
      #|  must have exactly one of exactly, atLeast and atMost
      #|  /count: is not a known field
      #|{ "exactly": -1 }:
      #|  /exactly: must be an integer of 0 or more
      #|{ "atLeast": 1.5 }:
      #|  /atLeast: must be an integer of 0 or more
      #|{ "atMost": "2" }:
      #|  /atMost: must be an integer of 0 or more
      #|{ "exactly": null }:
      #|  /exactly: must be an integer of 0 or more
      #|{ "atLeast": 1, "filter": { "path": "users", "since": 1 } }:
      #|  /filter/path: must start with /
      #|  /filter/since: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
      #|{ "atMost": 0, "limit": 10 }:
      #|  /limit: is not a known field
      #|{ "exactly": 0 }: Exactly(0)
      #|{ "atMost": 1e12, "filter": {} }: AtMost(2147483647)
    ),
  )
}
