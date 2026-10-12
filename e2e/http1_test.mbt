///|
async test "several requests in turn, with and without bodies, are answered on one keep-alive connection" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let responses = []
      conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
      responses.push(read_response(conn))
      conn.write(
        "POST /users/1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 13\r\n\r\n{\"name\":\"B\"}\n",
      )
      responses.push(read_response(conn))
      conn.write(
        "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      )
      responses.push(read_response(conn))
      inspect(
        responses.join("\n---\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
          #|---
          #|HTTP/1.1 404 Not Found
          #|Content-Type: application/json
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
          #|---
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Connection: close
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
      inspect(closed(conn), content="true")
    })
  })
}

///|
async test "a request that cannot be parsed gets 400 and the connection closes" {
  with_definitions([("users.json", users)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      conn.write("GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let first = read_response(conn)
      conn.write("GET /users/1 HTTP/1.1\r\nHost : localhost\r\n\r\n")
      let second = read_response(conn)
      inspect(
        first + "\n---\n" + second,
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
          #|---
          #|HTTP/1.1 400 Bad Request
          #|Connection: close
          #|Content-Length: 0
          #|
          #|
        ),
      )
      inspect(closed(conn), content="true")
    })
  })
}
