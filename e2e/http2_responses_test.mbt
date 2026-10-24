// Seam 2 tests of the responses smock writes on an HTTP/2 stream, over h2c:
// a Stub's status, headers and body adapted to HTTP/2's rules, framed as
// HTTP/1.1 frames them, compared with the same Stub's HTTP/1.1 response.

///|
/// A Mock that answers every Host, with a Stub whose headers HTTP/2 must
/// adapt: names in mixed case, a value with spaces and a tab around it, and
/// the fields HTTP/2 forbids in a response.
let adapted_headers : String =
  #|{ "mocks": [{ "name": "shop", "hosts": ["localhost"] }],
  #|  "stubs": [{ "id": "page", "mock": "shop",
  #|    "request": { "method": "GET", "path": "/page" },
  #|    "response": { "status": 200,
  #|      "headers": { "Cache-Control": "no-cache", "X-Request-Id": "  abc \t",
  #|        "Keep-Alive": "timeout=5", "Upgrade": "websocket",
  #|        "Proxy-Connection": "keep-alive", "TE": "trailers",
  #|        "X-Empty": " " },
  #|      "body": "page" } }] }

///|
async test "h2c: a Stub's header names go out in lower case, its values trimmed of spaces and tabs, and the fields HTTP/2 forbids in a response left out, where HTTP/1.1 sends them as written" {
  with_definitions([("shop.json", adapted_headers)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let h2 = client.request("GET", "/page", authority="localhost")
      let conn = smock.connect()
      defer conn.close()
      conn.write(raw_request("GET", "/page", host="localhost"))
      inspect(
        "\{h2.render()}\n---\n\{read_response(conn).escape()}",
        content=(
          #|200
          #|cache-control: no-cache
          #|x-request-id: abc
          #|x-empty: 
          #|date: <now>
          #|content-length: 4
          #|
          #|page
          #|---
          #|"HTTP/1.1 200 OK\nCache-Control: no-cache\nX-Request-Id:   abc \t\nKeep-Alive: timeout=5\nUpgrade: websocket\nProxy-Connection: keep-alive\nTE: trailers\nX-Empty:  \nDate: <now>\nContent-Length: 4\n\npage"
        ),
      )
    })
  })
}
