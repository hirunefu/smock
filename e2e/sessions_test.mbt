// Seam 2 tests of Sessions and Ephemeral Stubs: adding, listing, deleting
// and resetting them over the authenticated Admin API, and requests that
// carry a Session in their baggage header. Every Admin API response is
// checked against the OpenAPI document (contract_test.mbt).

///|
/// The `baggage` header that carries `session`, among other members.
fn baggage(session : String) -> (String, String) {
  ("baggage", "userId=alice,smock-session=\{session};ttl=60")
}

///|
/// Calls the Admin API with the test token, as `session` when it is given,
/// checks the response against the document, and returns its status and
/// body.
async fn Smock::call(
  self : Smock,
  meth : String,
  path : String,
  session? : String,
  body? : String,
) -> String {
  let headers = match session {
    Some(session) => [baggage(session)]
    None => []
  }
  let response = self.admin(meth, path, headers~, body?)
  conforms(meth, path, response)
  "\{response.status} \{response.body}"
}

///|
/// `GET /users/1` on the plain port, with the Session `session` when it is
/// given: the status line, the `Smock-Near-Miss` header if any, and the
/// body.
async fn Smock::user(
  self : Smock,
  session? : String,
  meth? : String = "GET",
) -> String {
  let headers = match session {
    Some(session) => [baggage(session)]
    None => []
  }
  let response = self.send(meth, "/users/1", headers~)
  let lines = response.split("\n").collect()
  let near_miss = lines
    .iter()
    .filter(line => line.has_prefix("Smock-Near-Miss:"))
    .map(line => " [\{line}]")
    .collect()
    .join("")
  "\{lines[0]}\{near_miss} \{lines[lines.length() - 1]}"
}

///|
/// An Ephemeral Stub that answers `GET /users/1` with `status` and `body`.
fn ephemeral_user(status : Int, body : String) -> String {
  "{\"request\":{\"method\":\"GET\",\"path\":\"/users/1\"},\"response\":{\"status\":\{status},\"body\":\"\{body}\"}}"
}

///|
async test "over the authenticated Admin API, Ephemeral Stubs are added, listed, deleted and reset, and answer only the requests that carry their Session" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      let step = (label : String, result : String) => {
        out.push("\{label}: \{result}")
      }
      let stubs = "/v1/mocks/users/stubs"
      step(
        "without a token",
        {
          let response = smock.admin("GET", stubs, token=None)
          conforms("GET", stubs, response)
          response.status.to_string()
        },
      )
      step(
        "test-a adds",
        smock.call(
          "POST",
          stubs,
          session="test-a",
          body=ephemeral_user(503, "down"),
        ),
      )
      step("test-a", smock.user(session="test-a"))
      step("test-b", smock.user(session="test-b"))
      step("no Session", smock.user())
      step("test-a, unmatched", smock.user(session="test-a", meth="POST"))
      step("test-a lists", smock.call("GET", stubs, session="test-a"))
      step("test-b lists", smock.call("GET", stubs, session="test-b"))
      step(
        "no Session adds",
        smock.call("POST", stubs, body=ephemeral_user(500, "boom")),
      )
      step("no Session", smock.user())
      step(
        "test-b deletes eph-1",
        smock.call("DELETE", "\{stubs}/eph-1", session="test-b"),
      )
      step(
        "test-a deletes eph-1",
        smock.call("DELETE", "\{stubs}/eph-1", session="test-a"),
      )
      step("test-a", smock.user(session="test-a"))
      step(
        "reset the no-Session space",
        smock.call("POST", "/v1/reset", body="{\"scope\":\"session\"}"),
      )
      step("no Session", smock.user())
      ignore(
        smock.call(
          "POST",
          stubs,
          session="test-a",
          body=ephemeral_user(503, "a"),
        ),
      )
      ignore(
        smock.call(
          "POST",
          stubs,
          session="test-b",
          body=ephemeral_user(503, "b"),
        ),
      )
      step(
        "reset test-a",
        smock.call(
          "POST",
          "/v1/reset",
          session="test-a",
          body="{\"scope\":\"session\"}",
        ),
      )
      step("test-b", smock.user(session="test-b"))
      step(
        "reset users",
        smock.call(
          "POST",
          "/v1/reset",
          body="{\"scope\":\"mock\",\"mock\":\"users\"}",
        ),
      )
      step("test-b", smock.user(session="test-b"))
      ignore(
        smock.call(
          "POST",
          stubs,
          session="test-c",
          body=ephemeral_user(503, "c"),
        ),
      )
      step(
        "reset all",
        smock.call("POST", "/v1/reset", body="{\"scope\":\"all\"}"),
      )
      step("test-c lists", smock.call("GET", stubs, session="test-c"))
      inspect(
        out.join("\n"),
        content=(
          #|without a token: 401
          #|test-a adds: 201 {"stub":{"id":"eph-1","mock":"users","session":"test-a","request":{"method":"GET","path":"/users/1"},"response":{"status":503,"body":"down"}},"warnings":[]}
          #|test-a: HTTP/1.1 503 Service Unavailable down
          #|test-b: HTTP/1.1 200 OK {"id":1,"name":"Alice"}
          #|no Session: HTTP/1.1 200 OK {"id":1,"name":"Alice"}
          #|test-a, unmatched: HTTP/1.1 404 Not Found [Smock-Near-Miss: eph-1; failed=method] {"error":"no Stub matched"}
          #|test-a lists: 200 {"stubs":[{"id":"eph-1","mock":"users","session":"test-a","request":{"method":"GET","path":"/users/1"},"response":{"status":503,"body":"down"}}],"warnings":[]}
          #|test-b lists: 200 {"stubs":[],"warnings":[]}
          #|no Session adds: 201 {"stub":{"id":"eph-2","mock":"users","session":null,"request":{"method":"GET","path":"/users/1"},"response":{"status":500,"body":"boom"}},"warnings":[]}
          #|no Session: HTTP/1.1 500 Internal Server Error boom
          #|test-b deletes eph-1: 404 {"error":"unknown_stub","message":"the calling Session has no Ephemeral Stub \"eph-1\" in the Mock \"users\"","warnings":[]}
          #|test-a deletes eph-1: 200 {"id":"eph-1","warnings":[]}
          #|test-a: HTTP/1.1 200 OK {"id":1,"name":"Alice"}
          #|reset the no-Session space: 200 {"scope":"session","removed":{"ephemeralStubs":1,"journalEntries":2},"warnings":[]}
          #|no Session: HTTP/1.1 200 OK {"id":1,"name":"Alice"}
          #|reset test-a: 200 {"scope":"session","removed":{"ephemeralStubs":1,"journalEntries":3},"warnings":[]}
          #|test-b: HTTP/1.1 503 Service Unavailable b
          #|reset users: 200 {"scope":"mock","removed":{"ephemeralStubs":1,"journalEntries":3},"warnings":[]}
          #|test-b: HTTP/1.1 200 OK {"id":1,"name":"Alice"}
          #|reset all: 200 {"scope":"all","removed":{"ephemeralStubs":1,"journalEntries":1},"warnings":[]}
          #|test-c lists: 200 {"stubs":[],"warnings":[]}
        ),
      )
    })
  })
}

///|
/// A Stub with problems `smock check` reports, without `id` and `mock`.
let invalid_stub : String =
  #|{ "request": { "method": "GET /", "path": { "pattern": "(" } },
  #|  "response": { "status": 99, "headers": { "Content-Length": "1" } },
  #|  "colour": "red" }

///|
async test "an invalid Ephemeral Stub gets 400 invalid_stub with the problems smock check reports for the same Stub in a Definition file" {
  let file = "{ \"mocks\": [{ \"name\": \"users\" }], \"stubs\": [" +
    invalid_stub.replace(old="{", new="{ \"id\": \"s\", \"mock\": \"users\",") +
    "] }"
  let mut checked = ""
  with_definitions([("users.json", file)], dir => checked = check([dir]))
  let _ = with_smock(["--port", "0"], smock => {
    let response = smock.admin(
      "POST",
      "/v1/mocks/default/stubs",
      body=invalid_stub,
    )
    conforms("POST", "/v1/mocks/default/stubs", response)
    guard response.json() is Object(error) &&
      error.get("message") is Some(String(message)) else {
      fail(response.body)
    }
    inspect(
      "\{response.status} \{error.get("error").map(e => e.stringify()).unwrap_or("")}\n\{message}\n---\nsmock check:\n\{checked}",
      content=(
        #|400 "invalid_stub"
        #|/request/method: must be an HTTP token, such as GET
        #|/request/path/pattern: is not a valid pattern: position 0: missing closing )
        #|/response/status: must be an integer from 200 to 599
        #|/response/headers/Content-Length: is set by smock and cannot be given
        #|/colour: is not a known field
        #|---
        #|smock check:
        #|status 1
        #|users.json: /stubs/0/request/method: must be an HTTP token, such as GET
        #|users.json: /stubs/0/request/path/pattern: is not a valid pattern: position 0: missing closing )
        #|users.json: /stubs/0/response/status: must be an integer from 200 to 599
        #|users.json: /stubs/0/response/headers/Content-Length: is set by smock and cannot be given
        #|users.json: /stubs/0/colour: is not a known field
        #|
      ),
    )
  })
}

///|
async test "Admin API errors on Ephemeral Stubs and reset: an unknown Mock, an id, a mock or a body file in the Stub, a missing body, a malformed reset" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let calls = [
        ("POST", "/v1/mocks/orders/stubs", Some(ephemeral_user(200, "x"))),
        ("GET", "/v1/mocks/orders/stubs", None),
        ("DELETE", "/v1/mocks/orders/stubs/eph-1", None),
        ("DELETE", "/v1/mocks/users/stubs/eph-1", None),
        ("POST", "/v1/reset", Some("{\"scope\":\"mock\",\"mock\":\"orders\"}")),
        (
          "POST",
          "/v1/mocks/users/stubs",
          Some(
            "{\"id\":\"mine\",\"mock\":\"users\",\"response\":{\"status\":200}}",
          ),
        ),
        (
          "POST",
          "/v1/mocks/users/stubs",
          Some("{\"response\":{\"status\":200,\"bodyFile\":\"users/1.json\"}}"),
        ),
        ("POST", "/v1/mocks/users/stubs", Some("[]")),
        ("POST", "/v1/mocks/users/stubs", None),
        ("POST", "/v1/reset", None),
        ("POST", "/v1/reset", Some("{\"scope\":\"everything\"}")),
        ("POST", "/v1/reset", Some("{\"scope\":\"mock\"}")),
        (
          "POST",
          "/v1/reset",
          Some("{\"scope\":\"session\",\"mock\":\"users\"}"),
        ),
        ("PUT", "/v1/mocks/users/stubs", None),
        ("GET", "/v1/mocks/users/stubs/eph-1", None),
      ]
      let out = []
      for call in calls {
        let (meth, path, body) = call
        out.push("\{meth} \{path}: \{smock.call(meth, path, body?)}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|POST /v1/mocks/orders/stubs: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|GET /v1/mocks/orders/stubs: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|DELETE /v1/mocks/orders/stubs/eph-1: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|DELETE /v1/mocks/users/stubs/eph-1: 404 {"error":"unknown_stub","message":"the no-Session space has no Ephemeral Stub \"eph-1\" in the Mock \"users\"","warnings":[]}
          #|POST /v1/reset: 404 {"error":"unknown_mock","message":"no Mock is named \"orders\": Mocks come only from Definition files","warnings":[]}
          #|POST /v1/mocks/users/stubs: 400 {"error":"invalid_stub","message":"/id: is not allowed in an Ephemeral Stub: smock assigns its ID\n/mock: is not allowed in an Ephemeral Stub: the Admin API path names its Mock","warnings":[]}
          #|POST /v1/mocks/users/stubs: 400 {"error":"invalid_stub","message":"/response/bodyFile: is not allowed in an Ephemeral Stub, whose body must be inline: give \"body\" instead","warnings":[]}
          #|POST /v1/mocks/users/stubs: 400 {"error":"invalid_stub","message":"must be an object","warnings":[]}
          #|POST /v1/mocks/users/stubs: 400 {"error":"invalid_request","message":"the body must be the Ephemeral Stub to add, a JSON object","warnings":[]}
          #|POST /v1/reset: 400 {"error":"invalid_request","message":"the body must be {\"scope\":\"session\"}, {\"scope\":\"mock\",\"mock\":<name>} or {\"scope\":\"all\"}","warnings":[]}
          #|POST /v1/reset: 400 {"error":"invalid_request","message":"the body must be {\"scope\":\"session\"}, {\"scope\":\"mock\",\"mock\":<name>} or {\"scope\":\"all\"}","warnings":[]}
          #|POST /v1/reset: 400 {"error":"invalid_request","message":"the body must be {\"scope\":\"session\"}, {\"scope\":\"mock\",\"mock\":<name>} or {\"scope\":\"all\"}","warnings":[]}
          #|POST /v1/reset: 400 {"error":"invalid_request","message":"the body must be {\"scope\":\"session\"}, {\"scope\":\"mock\",\"mock\":<name>} or {\"scope\":\"all\"}","warnings":[]}
          #|PUT /v1/mocks/users/stubs: 405 {"error":"method_not_allowed","message":"/v1/mocks/users/stubs takes GET, HEAD, POST, not PUT","warnings":[]}
          #|GET /v1/mocks/users/stubs/eph-1: 405 {"error":"method_not_allowed","message":"/v1/mocks/users/stubs/eph-1 takes DELETE, not GET","warnings":[]}
        ),
      )
    })
  })
}

///|
async test "a Mock name that is not a plain path segment is percent-encoded in the path" {
  let mocks =
    #|{ "mocks": [{ "name": "users api/v2" }] }
  with_definitions([("users.json", mocks)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let stubs = "/v1/mocks/users%20api%2Fv2/stubs"
      let out = [
        smock.call(
          "POST",
          stubs,
          session="%C3%A9",
          body=ephemeral_user(200, "x"),
        ),
        smock.call("GET", stubs, session="%C3%A9"),
        smock.call("DELETE", "\{stubs}/eph-1", session="%C3%A9"),
        smock.user(),
      ]
      inspect(
        out.join("\n"),
        content=(
          #|201 {"stub":{"id":"eph-1","mock":"users api/v2","session":"é","request":{"method":"GET","path":"/users/1"},"response":{"status":200,"body":"x"}},"warnings":[]}
          #|200 {"stubs":[{"id":"eph-1","mock":"users api/v2","session":"é","request":{"method":"GET","path":"/users/1"},"response":{"status":200,"body":"x"}}],"warnings":[]}
          #|200 {"id":"eph-1","warnings":[]}
          #|HTTP/1.1 404 Not Found {"error":"no Stub matched"}
        ),
      )
    })
  })
}

///|
async test "adding, deleting and resetting each write a JSON log entry; failed calls and requests write none" {
  with_definitions([("users.json", users)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let stubs = "/v1/mocks/users/stubs"
      ignore(
        smock.call(
          "POST",
          stubs,
          session="test-a",
          body=ephemeral_user(503, "a"),
        ),
      )
      ignore(smock.call("POST", stubs, body=ephemeral_user(503, "none")))
      ignore(smock.call("POST", stubs, body="{\"id\":\"x\"}"))
      ignore(
        smock.call(
          "POST",
          "/v1/mocks/orders/stubs",
          body=ephemeral_user(503, "x"),
        ),
      )
      ignore(smock.user(session="test-a"))
      ignore(smock.user(meth="POST"))
      ignore(smock.call("GET", stubs, session="test-a"))
      ignore(smock.call("DELETE", "\{stubs}/eph-1", session="test-a"))
      ignore(smock.call("DELETE", "\{stubs}/eph-1", session="test-a"))
      ignore(
        smock.call(
          "POST",
          "/v1/reset",
          session="test-a",
          body="{\"scope\":\"session\"}",
        ),
      )
      ignore(smock.call("POST", "/v1/reset", body="{\"scope\":\"session\"}"))
      ignore(
        smock.call(
          "POST",
          "/v1/reset",
          body="{\"scope\":\"mock\",\"mock\":\"users\"}",
        ),
      )
      ignore(smock.call("POST", "/v1/reset", body="{\"scope\":\"all\"}"))
      ignore(smock.call("POST", "/v1/reset", body="{\"scope\":\"none\"}"))
    })
    // The entries after the last `listening` one, which ends startup.
    let after = stopped.logs.length() -
      stopped.logs.rev().search_by(line => listening(line) is Some(_)).unwrap()
    inspect(
      entries(stopped.logs[after:].to_owned()),
      content=(
        #|{"level":"info","msg":"Ephemeral Stub added","mock":"users","session":"test-a","id":"eph-1"}
        #|{"level":"info","msg":"Ephemeral Stub added","mock":"users","session":null,"id":"eph-2"}
        #|{"level":"info","msg":"Ephemeral Stub deleted","mock":"users","session":"test-a","id":"eph-1"}
        #|{"level":"info","msg":"reset","scope":"session","session":"test-a","removed":{"ephemeralStubs":0,"journalEntries":1}}
        #|{"level":"info","msg":"reset","scope":"session","session":null,"removed":{"ephemeralStubs":1,"journalEntries":1}}
        #|{"level":"info","msg":"reset","scope":"mock","mock":"users","removed":{"ephemeralStubs":0,"journalEntries":0}}
        #|{"level":"info","msg":"reset","scope":"all","removed":{"ephemeralStubs":0,"journalEntries":0}}
      ),
    )
  })
}

///|
async test "the Session header and member are settings, by flag or SMOCK_ variable, for requests and Admin API calls alike" {
  let runs = [
    (
      "flags",
      ["--session-header", "X-Test-Context", "--session-member", "test-id"],
      Map([]),
    ),
    (
      "variables",
      [],
      {
        "SMOCK_SESSION_HEADER": "x-test-context",
        "SMOCK_SESSION_MEMBER": "test-id",
      },
    ),
  ]
  let out = []
  for run in runs {
    let (name, args, env) = run
    with_definitions([("users.json", users)], dir => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..args], env~, smock => {
        let context = [("X-Test-Context", "run=7,test-id=t1")]
        let added = smock.admin(
          "POST",
          "/v1/mocks/users/stubs",
          headers=context,
          body=ephemeral_user(503, "t1"),
        )
        conforms("POST", "/v1/mocks/users/stubs", added)
        out.push("\{name}: added \{added.status}")
        for
          request in [
            ("X-Test-Context", context),
            ("baggage", [baggage("t1")]),
            ("none", []),
          ] {
          let response = smock.send("GET", "/users/1", headers=request.1)
          let status = response.split("\n").collect()[0]
          out.push("\{name}: \{request.0}: \{status}")
        }
      })
    })
  }
  inspect(
    out.join("\n"),
    content=(
      #|flags: added 201
      #|flags: X-Test-Context: HTTP/1.1 503 Service Unavailable
      #|flags: baggage: HTTP/1.1 200 OK
      #|flags: none: HTTP/1.1 200 OK
      #|variables: added 201
      #|variables: X-Test-Context: HTTP/1.1 503 Service Unavailable
      #|variables: baggage: HTTP/1.1 200 OK
      #|variables: none: HTTP/1.1 200 OK
    ),
  )
}
