// Seam 2 tests of the mockoon log format over HTTP/2, h2c on the plain port
// and h2 on the TLS port: each request a Mock handles writes one
// Transaction recorded line to stdout, as over HTTP/1.1, once its stream's
// response has ended, however it ends. Lines are compared whole, byte for
// byte, with only the value of `timestamp` masked, once its form is checked.

///|
async test "h2c and h2: with SMOCK_LOG_FORMAT=mockoon, each request a Mock handles writes one Transaction recorded line, with :method and :path up to ?, as over HTTP/1.1" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let _ = with_smock(args, env~, smock => {
        let out = []
        for tls in [false, true] {
          let client = if tls { smock.h2() } else { smock.h2c() }
          defer client.close()
          let requests = [
            ("GET", "/users/1?verbose=true", "localhost"),
            ("GET", "/users/a%20b", "localhost"),
            ("GET", "/orders/1", "unknown.example.com"),
          ]
          for request in requests {
            let (meth, path, authority) = request
            let response = client.request(meth, path, authority~)
            out.push("\{meth} \{path}: \{response.status}")
          }
        }
        // Read while smock runs: a line held in a buffer would not come.
        let lines = smock.transaction_lines(6)
        out.push(masked_lines(lines))
        inspect(
          out.join("\n"),
          content=(
            #|GET /users/1?verbose=true: 200
            #|GET /users/a%20b: 404
            #|GET /orders/1: 404
            #|GET /users/1?verbose=true: 200
            #|GET /users/a%20b: 404
            #|GET /orders/1: 404
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/a%20b","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/a%20b","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
          ),
        )
      })
    })
  })
}

///|
async test "h2c: a delayed response logs after its delay, while a fast stream on the connection logs at once, and a Server-Sent Event stream logs once, after its last event" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let delayed = client.send("GET", "/delayed", authority="localhost")
      let quick = client.request("GET", "/quick", authority="localhost")
      out.push("/quick answers: \{quick.status}")
      let line = smock.transaction_lines(1)[0]
      out.push(mask_timestamp(line))
      out.push("written during the delay: \{written_at(line) - start < 1000}")
      out.push("/delayed answers: \{client.response(delayed).status}")
      let line = smock.transaction_lines(2)[1]
      out.push(mask_timestamp(line))
      out.push("written after the delay: \{written_at(line) - start >= 1000}")
      let start = @async.now()
      let stream = client.send("GET", "/stream", authority="localhost")
      guard client.stream_event(stream) is Response(_) else {
        fail("no HEADERS")
      }
      guard client.stream_event(stream) is Data(_) else {
        fail("no first event")
      }
      @async.sleep(300)
      out.push(
        "after the first event: \{transactions(smock.stdout).length() - 2} lines",
      )
      let rest = client.response(stream)
      out.push("/stream ends: \{rest.ended}")
      let line = smock.transaction_lines(3)[2]
      out.push(mask_timestamp(line))
      out.push(
        "written after the last event: \{written_at(line) - start >= 1000}",
      )
      // The stream is one request: no more lines come.
      @async.sleep(300)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      inspect(
        out.join("\n"),
        content=(
          #|/quick answers: 200
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/quick","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written during the delay: true
          #|/delayed answers: 200
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the delay: true
          #|after the first event: 0 lines
          #|/stream ends: end
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stream","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the last event: true
          #|lines in all: 3
        ),
      )
    })
  })
}
