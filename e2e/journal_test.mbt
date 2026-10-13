// Seam 2 tests of the Journal: requests recorded by the running smock and
// queried over the authenticated Admin API, for the calling Session. Every
// Admin API response is checked against the OpenAPI document
// (contract_test.mbt).

///|
/// Two Mocks for their own Hosts, without a Default Mock: `users`, with a
/// Stub, Stubs whose connection Faults close the connection or send half a
/// response, and a stream of Server-Sent Events; and `orders`, whose
/// Journal is off.
let journal_defs : String =
  #|{ "mocks": [
  #|    { "name": "users", "hosts": ["users.example.com", "localhost"] },
  #|    { "name": "orders", "hosts": ["orders.example.com"], "journal": false } ],
  #|  "stubs": [
  #|    { "id": "get-user", "mock": "users",
  #|      "request": { "method": "GET", "path": { "pattern": "/users/[0-9]+" } },
  #|      "response": { "status": 200, "body": "Alice" } },
  #|    { "id": "close", "mock": "users", "request": { "path": "/close" },
  #|      "response": { "status": 200 },
  #|      "fault": { "connection": { "kind": "close" } } },
  #|    { "id": "partial", "mock": "users", "request": { "path": "/partial" },
  #|      "response": { "status": 200, "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial" } } },
  #|    { "id": "events", "mock": "users", "request": { "path": "/events" },
  #|      "response": { "status": 200, "events": [
  #|        { "delay": 300, "data": "first" },
  #|        { "delay": 300, "data": "second" },
  #|        { "delay": 300, "data": "last" } ] } },
  #|    { "id": "get-order", "mock": "orders", "request": { "path": "/orders/1" },
  #|      "response": { "status": 200 } } ] }

///|
/// Queries the Journal as `session`, with the query `query`, checks the
/// response against the document, and returns its status and body.
async fn Smock::journal(
  self : Smock,
  session? : String,
  query? : String = "{}",
) -> (Int, Json) {
  let headers = match session {
    Some(session) => [baggage(session)]
    None => []
  }
  let response = self.admin("POST", "/v1/journal/query", headers~, body=query)
  (response.status, response.json())
}

///|
/// The number of entries a query as `session` with `query` returns.
async fn Smock::journal_count(
  self : Smock,
  session : String,
  query : String,
) -> Int {
  match self.journal(session~, query~) {
    (200, Object({ "entries": Array(entries), .. })) => entries.length()
    (status, body) => fail("the query failed: \{status} \{body.stringify()}")
  }
}

///|
/// `json` with the values that differ from run to run replaced: when the
/// entries were received, how long they took and the digest.
fn journal_shown(json : Json) -> Json {
  match json {
    Object(members) => {
      let out = Map([])
      for name, value in members {
        out[name] = match (name, value) {
          ("receivedAt", String(_)) => Json::string("<time>")
          ("durationMs", Number(_, ..)) => Json::string("<ms>")
          ("digest", String(_)) => Json::string("<digest>")
          _ => journal_shown(value)
        }
      }
      Json::object(out)
    }
    Array(items) => Json::array(items.map(journal_shown))
    _ => json
  }
}

///|
/// Sends `<meth> <target>` as raw bytes on a new connection to the plain
/// port, with `headers` and `body`, and reads the response.
async fn Smock::request(
  self : Smock,
  meth : String,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> String {
  let conn = self.connect()
  defer conn.close()
  let request = StringBuilder()
  request.write_string("\{meth} \{target} HTTP/1.1\r\n")
  for header in headers {
    request.write_string("\{header.0}: \{header.1}\r\n")
  }
  request.write_string(
    "Content-Length: \{@utf8.encode(body).length()}\r\n\r\n\{body}",
  )
  conn.write(request.to_string())
  read_response(conn)
}

///|
async test "a request is in the Journal as soon as its client has the whole response: a query right after each response finds it, many times in a row" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let missed = []
      for i in 0..<50 {
        conn.write(
          "GET /users/\{i} HTTP/1.1\r\nHost: users.example.com\r\nbaggage: smock-session=right-after\r\n\r\n",
        )
        let response = read_response(conn)
        guard response.has_prefix("HTTP/1.1 200 OK") else {
          fail("unexpected response: \{response}")
        }
        let found = smock.journal_count(
          "right-after",
          "{\"filter\":{\"path\":\"/users/\{i}\"}}",
        )
        if found != 1 {
          missed.push("/users/\{i}: \{found} entries")
        }
      }
      debug_inspect(missed, content="[]")
    })
  })
}

///|
async test "a query returns the calling Session's entries, oldest first, as the document defines them: the Stub or the Near miss, and an unknown Host with no Mock" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let session = baggage("shown")
      let _ = smock.request("GET", "/users/1?x=y", headers=[
        ("Host", "users.example.com"),
        session,
      ])
      let _ = smock.request("POST", "/users/1", body="hello", headers=[
        ("Host", "users.example.com"),
        session,
      ])
      let _ = smock.request("GET", "/users/1", headers=[
        ("Host", "nowhere.example.com"),
        session,
      ])
      // The Journal of orders is off, and other Sessions are apart.
      let _ = smock.request("GET", "/orders/1", headers=[
        ("Host", "orders.example.com"),
        session,
      ])
      let _ = smock.request("GET", "/users/2", headers=[
        ("Host", "users.example.com"),
        baggage("other"),
      ])
      let (status, page) = smock.journal(session="shown")
      inspect(status, content="200")
      json_inspect(journal_shown(page), content={
        "entries": [
          {
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "shown",
            "host": "users.example.com",
            "mock": "users",
            "viaDefault": false,
            "digest": "<digest>",
            "request": {
              "method": "GET",
              "target": "/users/1?x=y",
              "version": "HTTP/1.1",
              "headers": [
                { "name": "Host", "value": "users.example.com" },
                {
                  "name": "baggage",
                  "value": "userId=alice,smock-session=shown;ttl=60",
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
            "stub": "get-user",
            "nearMiss": Json::null(),
            "status": 200,
            "fault": Json::null(),
          },
          {
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "shown",
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
                  "value": "userId=alice,smock-session=shown;ttl=60",
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
            "nearMiss": {
              "stub": "get-user",
              "failed": [
                { "condition": "method", "expected": "GET", "actual": ["POST"] },
              ],
            },
            "status": 404,
            "fault": Json::null(),
          },
          {
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "shown",
            "host": "nowhere.example.com",
            "mock": Json::null(),
            "viaDefault": false,
            "digest": "<digest>",
            "request": {
              "method": "GET",
              "target": "/users/1",
              "version": "HTTP/1.1",
              "headers": [
                { "name": "Host", "value": "nowhere.example.com" },
                {
                  "name": "baggage",
                  "value": "userId=alice,smock-session=shown;ttl=60",
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
async test "a stream of Server-Sent Events is in the Journal once its last event has arrived, not before" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      conn.write(
        "GET /events HTTP/1.1\r\nHost: localhost\r\nbaggage: smock-session=sse\r\n\r\n",
      )
      let streamed = @async.with_timeout_opt(patience_ms, () => {
        let _ = conn.read_until("\r\n\r\n")
        let _ = conn.read_until("data: first\n\n")
        let after_first = smock.journal_count("sse", "{}")
        let _ = conn.read_until("data: last\n\n")
        let after_last = smock.journal_count("sse", "{}")
        "after the first event: \{after_first}, after the last: \{after_last}"
      })
      inspect(
        streamed.unwrap_or("the stream did not arrive in time"),
        content="after the first event: 0, after the last: 1",
      )
    })
  })
}

///|
async test "a request ended by a close or partial connection Fault is in the Journal once the connection has closed" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for target in ["/close", "/partial"] {
        let conn = smock.connect()
        defer conn.close()
        conn.write(
          "GET \{target} HTTP/1.1\r\nHost: localhost\r\nbaggage: smock-session=faults\r\n\r\n",
        )
        let _ = read_to_end(conn)
        guard smock.journal(session="faults")
          is (200, Object({ "entries": Array(entries), .. })) &&
          entries.last() is Some(Object(entry)) else {
          fail("no entry for \{target}")
        }
        out.push(
          "\{target}: \{entries.length()} entries, the last with status \{entry["status"].stringify()} and fault \{entry["fault"].stringify()}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|/close: 1 entries, the last with status null and fault "close"
          #|/partial: 2 entries, the last with status 200 and fault "partial"
        ),
      )
    })
  })
}

///|
async test "a request ended by a reset Fault is in the Journal, body included, as soon as its client sees the reset, many times in a row" {
  let defs =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [{ "id": "reset", "mock": "m",
    #|    "request": { "path": { "pattern": "/reset/[0-9]+" } },
    #|    "response": { "status": 200, "body": "never sent" },
    #|    "fault": { "connection": { "kind": "reset" } } }] }
  with_definitions([("m.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let missed = []
      for i in 0..<20 {
        let conn = smock.connect()
        defer conn.close()
        conn.write(
          "POST /reset/\{i} HTTP/1.1\r\nHost: localhost\r\nbaggage: smock-session=resets\r\nContent-Length: 5\r\n\r\nhello",
        )
        let ended = how_it_ends(conn)
        guard ended == "0 bytes, then an RST" else {
          fail("/reset/\{i}: \{ended}")
        }
        let found = smock.journal_count(
          "resets",
          "{\"filter\":{\"path\":\"/reset/\{i}\"}}",
        )
        if found != 1 {
          missed.push("/reset/\{i}: \{found} entries")
        }
      }
      debug_inspect(missed, content="[]")
      let (_, page) = smock.journal(
        session="resets",
        query="{\"filter\":{\"path\":\"/reset/0\"}}",
      )
      json_inspect(journal_shown(page), content={
        "entries": [
          {
            "receivedAt": "<time>",
            "durationMs": "<ms>",
            "session": "resets",
            "host": "localhost",
            "mock": "m",
            "viaDefault": true,
            "digest": "<digest>",
            "request": {
              "method": "POST",
              "target": "/reset/0",
              "version": "HTTP/1.1",
              "headers": [
                { "name": "Host", "value": "localhost" },
                { "name": "baggage", "value": "smock-session=resets" },
                { "name": "Content-Length", "value": "5" },
              ],
              "body": {
                "encoding": "utf-8",
                "data": "hello",
                "size": 5,
                "truncated": false,
              },
            },
            "stub": "reset",
            "nearMiss": null,
            "status": null,
            "fault": "reset",
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
async test "a query is refused with journal_off when its filter names a Mock whose Journal is off, or when the Journal is off globally" {
  with_definitions([("users.json", journal_defs)], dir => {
    let out = []
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let (status, body) = smock.journal(
        session="s",
        query="{\"filter\":{\"mock\":\"orders\"}}",
      )
      out.push("orders: \{status} \{body.stringify()}")
      let (status, _) = smock.journal(
        session="s",
        query="{\"filter\":{\"mock\":\"users\"}}",
      )
      out.push("users: \{status}")
    })
    let _ = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_JOURNAL": "off" },
      smock => {
        let _ = smock.request("GET", "/users/1", headers=[("Host", "localhost")])
        let (status, body) = smock.journal()
        out.push("--journal off: \{status} \{body.stringify()}")
      },
    )
    inspect(
      out.join("\n"),
      content=(
        #|orders: 409 {"error":"journal_off","message":"the Journal is off for the Mock \"orders\" (\"journal\": false in the Definition files): smock records none of its requests","warnings":[]}
        #|users: 200
        #|--journal off: 409 {"error":"journal_off","message":"the Journal is off (--journal off): smock records no request","warnings":[]}
      ),
    )
  })
}

///|
async test "a query that does not have the shape of the document is refused with invalid_request, naming every problem" {
  let _ = with_smock(["--port", "0"], smock => {
    let out = []
    for
      body in [
        None,
        Some("[]"),
        Some("{\"filter\":{\"path\":\"users\",\"since\":\"now\"},\"limit\":0}"),
        Some("{\"filter\":{\"headers\":{\"X-Id\":{\"pattern\":\"(\"}}}}"),
      ] {
      let response = smock.admin("POST", "/v1/journal/query", body?)
      out.push("\{response.status} \{response.body}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|400 {"error":"invalid_request","message":"the body must be a Journal query: a JSON object, such as {\"filter\":{\"path\":\"/users/1\"},\"limit\":10}","warnings":[]}
        #|400 {"error":"invalid_request","message":"the query is not valid: must be an object","warnings":[]}
        #|400 {"error":"invalid_request","message":"the query is not valid: /filter/path: must start with /\n/filter/since: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z\n/limit: must be an integer from 1 to 10000","warnings":[]}
        #|400 {"error":"invalid_request","message":"the query is not valid: /filter/headers/X-Id/pattern: is not a valid pattern: position 0: missing closing )","warnings":[]}
      ),
    )
  })
}

///|
async test "the Journal bound and body truncation are settings: the oldest entries are evicted and counted for their Session, and bodies are cut" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--journal-max-entries", "2"],
      env={ "SMOCK_JOURNAL_BODY_LIMIT": "3" },
      smock => {
        for i in 1..<=3 {
          let _ = smock.request("GET", "/users/\{i}", body="abcdef", headers=[
            ("Host", "localhost"),
            baggage("bound"),
          ])
        }
        guard smock.journal(session="bound")
          is (200, Object({ "entries": Array(entries), "evicted": evicted, .. })
          ) else {
          fail("the query failed")
        }
        let shown = entries.map(entry => {
          guard entry
            is Object(
              {
                "request": Object(
                  { "target": String(target), "body": body, .. }
                ),
                ..
              }
            ) else {
            return "?"
          }
          "\{target} \{body.stringify()}"
        })
        inspect(
          "\{shown.join("\n")}\nevicted: \{evicted.stringify()}",
          content=(
            #|/users/2 {"encoding":"utf-8","data":"abc","size":6,"truncated":true}
            #|/users/3 {"encoding":"utf-8","data":"abc","size":6,"truncated":true}
            #|evicted: 1
          ),
        )
      },
    )
  })
}

///|
async test "reset clears the calling Session's Journal entries and says how many it removed" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      for session in ["test-a", "test-a", "test-b"] {
        let _ = smock.request("GET", "/users/1", headers=[
          ("Host", "localhost"),
          baggage(session),
        ])
      }
      let out = [
        smock.call(
          "POST",
          "/v1/reset",
          session="test-a",
          body="{\"scope\":\"session\"}",
        ),
        "test-a: \{smock.journal_count("test-a", "{}")} entries",
        "test-b: \{smock.journal_count("test-b", "{}")} entries",
        smock.call(
          "POST",
          "/v1/reset",
          body="{\"scope\":\"mock\",\"mock\":\"users\"}",
        ),
        "test-b: \{smock.journal_count("test-b", "{}")} entries",
      ]
      inspect(
        out.join("\n"),
        content=(
          #|200 {"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":2},"warnings":[]}
          #|test-a: 0 entries
          #|test-b: 1 entries
          #|200 {"scope":"mock","removed":{"ephemeralStubs":0,"journalEntries":1},"warnings":[]}
          #|test-b: 0 entries
        ),
      )
    })
  })
}

///|
async test "/metrics shows the Journal's entries, bytes and evictions, without labels" {
  with_definitions([("users.json", journal_defs)], dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--journal-max-entries", "2"],
      smock => {
        for i in 1..<=3 {
          let _ = smock.request("GET", "/users/\{i}", headers=[
            ("Host", "localhost"),
          ])
        }
        let response = smock.admin("GET", "/metrics")
        let lines = response.body
          .split("\n")
          .filter(line => line.contains("smock_journal_"))
          .map(line => {
            // The bytes depend on the request, not on what this test shows.
            if line.has_prefix("smock_journal_bytes ") {
              "smock_journal_bytes <bytes>"
            } else {
              line.to_owned()
            }
          })
          .collect()
        inspect(
          lines.join("\n"),
          content=(
            #|# HELP smock_journal_entries Entries the Journal holds.
            #|# TYPE smock_journal_entries gauge
            #|smock_journal_entries 2
            #|# HELP smock_journal_bytes Bytes the Journal's entries take, as they count them against its byte bound (--journal-max-bytes).
            #|# TYPE smock_journal_bytes gauge
            #|smock_journal_bytes <bytes>
            #|# HELP smock_journal_evictions_total Journal entries evicted because the Journal was full (--journal-max-entries, --journal-max-bytes).
            #|# TYPE smock_journal_evictions_total counter
            #|smock_journal_evictions_total 1
          ),
        )
      },
    )
  })
}
