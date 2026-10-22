// Seam 2 tests of Variables: a Stub's `variables` written by one request
// and read by the next, over real sockets, one connection per request.

///|
/// The example of ticket #87: `POST /login` stores the user it is sent and
/// the one stored before, and echoes both; `GET /me` reads the user back.
let who_logged_in : String =
  #|mocks:
  #|  - name: shop
  #|stubs:
  #|  - id: login
  #|    mock: shop
  #|    request: { method: POST, path: /login }
  #|    variables:
  #|      user: ${body.user}
  #|      previous: ${vars.user ?? null}
  #|    response:
  #|      status: 200
  #|      template: true
  #|      json: { user: "${vars.user}", previous: "${vars.previous}" }
  #|  - id: whoami
  #|    mock: shop
  #|    request: { method: GET, path: /me }
  #|    response:
  #|      status: 200
  #|      template: true
  #|      json: { user: "${vars.user ?? null}" }

///|
async test "over HTTP, a POST stores a value that a GET of the same Session reads, and another Session does not see it" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let json = [("Content-Type", "application/json")]
      let out = [
        smock.send("GET", "/me", headers=[baggage("test-a")]),
        smock.send(
          "POST",
          "/login",
          headers=[baggage("test-a"), ..json],
          body="{\"user\":\"ann\"}",
        ),
        smock.send("GET", "/me", headers=[baggage("test-a")]),
        smock.send("GET", "/me", headers=[baggage("test-b")]),
      ]
      inspect(
        out.join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Date: <now>
          #|Content-Length: 13
          #|
          #|{"user":null}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Date: <now>
          #|Content-Length: 30
          #|
          #|{"user":"ann","previous":null}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Date: <now>
          #|Content-Length: 14
          #|
          #|{"user":"ann"}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Date: <now>
          #|Content-Length: 13
          #|
          #|{"user":null}
        ),
      )
    })
  })
}

///|
async test "over the Admin API, a Session reset clears the Session's Variables, and counts them in its response and in its log entry" {
  with_definitions([("shop.yaml", who_logged_in)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let json = [("Content-Type", "application/json")]
      let login = (session : String, user : String) => {
        smock.send(
          "POST",
          "/login",
          headers=[baggage(session), ..json],
          body="{\"user\":\"\{user}\"}",
        )
        |> ignore
      }
      let me = (session : String) => smock.order("GET", "/me", session~)
      login("test-a", "ann")
      login("test-b", "bob")
      let out = [
        "reset test-a: " +
        smock.call(
          "POST",
          "/v1/reset",
          session="test-a",
          body="{\"scope\":\"session\"}",
        ),
        "test-a GET /me: \{me("test-a")}",
        "test-b GET /me: \{me("test-b")}",
      ]
      inspect(
        out.join("\n"),
        content=(
          #|reset test-a: 200 {"scope":"session","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":2,"dataBuckets":0},"warnings":[]}
          #|test-a GET /me: 200 {"user":null}
          #|test-b GET /me: 200 {"user":"bob"}
        ),
      )
    })
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"reset\"")),
      ),
      content=(
        #|{"level":"info","msg":"reset","scope":"session","session":"test-a","removed":{"ephemeralStubs":0,"journalEntries":1,"scenarioStates":0,"variables":2,"dataBuckets":0}}
      ),
    )
  })
}
