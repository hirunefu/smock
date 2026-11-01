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
