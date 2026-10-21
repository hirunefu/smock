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
          #|Content-Length: 13
          #|
          #|{"user":null}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Content-Length: 30
          #|
          #|{"user":"ann","previous":null}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Content-Length: 14
          #|
          #|{"user":"ann"}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|Smock-Mock: shop; via=default
          #|Content-Length: 13
          #|
          #|{"user":null}
        ),
      )
    })
  })
}
