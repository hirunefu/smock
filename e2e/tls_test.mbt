// HTTPS on the TLS port. The clients trust only the test root CA, so a
// handshake succeeds only when smock sends the intermediate CA along with
// its leaf certificate.

///|
/// `GET /users/1`, asking smock to close the connection after answering.
let get_user : String = "GET /users/1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

///|
/// Sends `request` on a new connection and reads one response.
async fn Smock::exchange(self : Smock, over : Over, request : String) -> String {
  let conn = self.connect(over~)
  defer conn.close()
  conn.write(request)
  read_response(conn)
}

///|
/// `text` with the temporary directory of `certs` shown as `$CERTS`.
fn hide_dir(text : String, certs : Certificates) -> String {
  text.replace_all(old=certs.dir, new="$CERTS")
}

///|
async test "with a certificate chain and its key, smock serves HTTPS on the TLS port with the same responses as on the plain port, for RSA and ECDSA keys" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let out = []
      let pairs = [
        ("RSA", certs.rsa_chain, certs.rsa_key),
        ("ECDSA", certs.ecdsa_chain, certs.ecdsa_key),
      ]
      for pair in pairs {
        let (kind, cert, key) = pair
        let _ = with_smock(
          ["--dir", dir, "--port", "0", ..certs.args(cert~, key~)],
          smock => {
            let plain = smock.exchange(Plain, get_user)
            let tls = smock.exchange(Tls(certs), get_user)
            out.push(
              "\{kind}, same as on the plain port: \{tls == plain}\n\{tls}",
            )
          },
        )
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|RSA, same as on the plain port: true
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Connection: close
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
          #|---
          #|ECDSA, same as on the plain port: true
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
          #|Smock-Mock: users; via=default
          #|Date: <now>
          #|Connection: close
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
        ),
      )
    })
  })
}

///|
async test "smock serve refuses to start when only one TLS file is set, a file cannot be read or parsed, or the key does not match the certificate" {
  with_certificates(certs => {
    let missing = "\{certs.dir}/missing.pem"
    let not_pem = "\{certs.dir}/notes.txt"
    write(certs.dir, "notes.txt", "not PEM\n")
    // A directory, such as a Secret volume, instead of a file in it.
    let secret_dir = "\{certs.dir}/secret"
    @fs.mkdir(secret_dir)
    let runs : Array[(Array[String], Map[String, String])] = [
      (["--tls-cert-file", certs.rsa_chain], Map([])),
      ([], { "SMOCK_TLS_KEY_FILE": certs.rsa_key }),
      (["--tls-cert-file", "", "--tls-key-file", certs.rsa_key], Map([])),
      (certs.args(cert=missing), Map([])),
      (certs.args(key=missing), Map([])),
      (certs.args(cert=secret_dir), Map([])),
      (certs.args(cert=not_pem), Map([])),
      (certs.args(cert=certs.rsa_key), Map([])),
      (certs.args(key=not_pem), Map([])),
      (certs.args(key=certs.rsa_chain), Map([])),
      (certs.args(key=certs.other_key), Map([])),
      (certs.args(key=certs.ecdsa_key), Map([])),
      (certs.args(cert=certs.ecdsa_chain), Map([])),
    ]
    let out = []
    for run in runs {
      let (args, env) = run
      let stopped = run_smock(["serve", "--port", "0", ..args], env~)
      out.push(
        hide_dir(
          "status \{stopped.status}\n\{log_entries(stopped.logs)}",
          certs,
        ),
      )
    }
    inspect(
      out.join("\n---\n"),
      content=(
        #|status 2
        #|not JSON: smock serve: invalid value "$CERTS/rsa-chain.pem" for --tls-cert-file (SMOCK_TLS_CERT_FILE): needs --tls-key-file (SMOCK_TLS_KEY_FILE) as well
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "$CERTS/rsa-key.pem" for --tls-key-file (SMOCK_TLS_KEY_FILE): needs --tls-cert-file (SMOCK_TLS_CERT_FILE) as well
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "" for --tls-cert-file (SMOCK_TLS_CERT_FILE): must not be empty
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/missing.pem","keyFile":"*/rsa-key.pem","error":"cannot read the certificate file: no such file"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-chain.pem","keyFile":"*/missing.pem","error":"cannot read the key file: no such file"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/secret","keyFile":"*/rsa-key.pem","error":"cannot read the certificate file: is a directory"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/notes.txt","keyFile":"*/rsa-key.pem","error":"certificate file: no PEM certificate found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-key.pem","keyFile":"*/rsa-key.pem","error":"certificate file: no PEM certificate found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-chain.pem","keyFile":"*/notes.txt","error":"key file: no PEM private key found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-chain.pem","keyFile":"*/rsa-chain.pem","error":"key file: no PEM private key found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-chain.pem","keyFile":"*/other-key.pem","error":"the private key does not match the leaf certificate"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/rsa-chain.pem","keyFile":"*/ecdsa-key.pem","error":"the private key does not match the leaf certificate"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"","certFile":"*/ecdsa-chain.pem","keyFile":"*/rsa-key.pem","error":"the private key does not match the leaf certificate"}
      ),
    )
  })
}

///|
async test "the TLS settings can come from SMOCK_ environment variables, and the listening entry of the TLS port names its certificate files" {
  with_certificates(certs => {
    let stopped = with_smock(
      [],
      env={
        "SMOCK_PORT": "0",
        "SMOCK_TLS_PORT": "0",
        "SMOCK_TLS_CERT_FILE": certs.ecdsa_chain,
        "SMOCK_TLS_KEY_FILE": certs.ecdsa_key,
      },
      smock => {
        let response = smock.exchange(Tls(certs), get_user)
        inspect(response.has_prefix("HTTP/1.1 404 Not Found"), content="true")
      },
    )
    inspect(
      log_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","certFile":"*/ecdsa-chain.pem","keyFile":"*/ecdsa-key.pem"}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
/// Runs `openssl s_client` against the TLS port with `options`, trusting
/// only the PEM certificates in the file `ca` (by default the test root CA
/// of `certs`), sends `request` once the handshake is done, and returns its
/// exit status and, for each group of prefixes in `show`, the first line it
/// printed that starts with one of them. By default these are what ALPN
/// selected, the certificate verification result and the response's status
/// line. The request goes through a file in `certs.dir`.
async fn Smock::s_client(
  self : Smock,
  certs : Certificates,
  options : Array[String],
  request : String,
  ca? : String = certs.ca,
  show? : Array[Array[String]] = [
    ["ALPN protocol:", "No ALPN negotiated"],
    ["Verify return code:"],
    ["HTTP/"],
  ],
) -> String {
  write(certs.dir, "request.txt", request)
  let result = @async.with_timeout_opt(patience_ms, () => {
    collect_output(
      "openssl",
      [
        "s_client",
        "-connect",
        "127.0.0.1:\{self.tls_port}",
        "-CAfile",
        ca,
        "-verify_return_error",
        "-ign_eof",
        ..options,
      ],
      stdin=@process.redirect_from_file("\{certs.dir}/request.txt"),
    )
  })
  guard result is Some((status, stdout, _)) else {
    fail("openssl s_client did not exit in time")
  }
  let lines = stdout
    .text()
    .split("\n")
    .map(line => line.trim_end(chars="\r"))
    .collect()
  let first = (prefixes : Array[String]) => {
    lines
    .iter()
    .filter(line => prefixes.iter().any(prefix => line.has_prefix(prefix)))
    .map(line => line.to_owned())
    .collect()
    .get(0)
    .unwrap_or("(none of \{prefixes.join(", ")})")
  }
  ["status \{status}", ..show.map(first)].join("\n")
}

///|
async test "ALPN: a client offering h2 and http/1.1 gets http/1.1, and a client that sends no ALPN is served" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let out = []
        let offers = [
          ("h2 and http/1.1", ["-alpn", "h2,http/1.1"]),
          ("no ALPN", []),
        ]
        for offer in offers {
          let (label, options) = offer
          out.push("\{label}:\n" + smock.s_client(certs, options, get_user))
        }
        inspect(
          out.join("\n---\n"),
          content=(
            #|h2 and http/1.1:
            #|status 0
            #|ALPN protocol: http/1.1
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
            #|---
            #|no ALPN:
            #|status 0
            #|No ALPN negotiated
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
          ),
        )
      })
    })
  })
}

///|
/// Two Mocks with Hosts, each with a Stub `GET /x` that answers with its
/// name on a line of its own.
let users_and_orders : Array[(String, String)] = [
  (
    "mocks.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] },
      #|            { "name": "orders", "hosts": ["orders.example.com"] }],
      #|  "stubs": [{ "id": "users-x", "mock": "users",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "body": "from users\n" } },
      #|            { "id": "orders-x", "mock": "orders",
      #|              "request": { "method": "GET", "path": "/x" },
      #|              "response": { "status": 200, "body": "from orders\n" } }] }
    ),
  ),
]

///|
async test "SNI never chooses the Mock: a request whose SNI names one Mock's Host and whose Host header names another's is answered by the Mock of its Host header" {
  with_definitions(users_and_orders, dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let out = []
        let cases = [
          ("orders.example.com", "users.example.com"),
          ("users.example.com", "orders.example.com"),
          ("unknown.example.com", "orders.example.com"),
        ]
        for case in cases {
          let (sni, host) = case
          let request = "GET /x HTTP/1.1\r\nHost: \{host}\r\nConnection: close\r\n\r\n"
          out.push(
            "SNI \{sni}, Host \{host}:\n" +
            smock.s_client(certs, ["-servername", sni], request, show=[
              ["Verify return code:"],
              ["HTTP/"],
              ["from "],
            ]),
          )
        }
        inspect(
          out.join("\n---\n"),
          content=(
            #|SNI orders.example.com, Host users.example.com:
            #|status 0
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
            #|from users
            #|---
            #|SNI users.example.com, Host orders.example.com:
            #|status 0
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
            #|from orders
            #|---
            #|SNI unknown.example.com, Host orders.example.com:
            #|status 0
            #|Verify return code: 0 (ok)
            #|HTTP/1.1 200 OK
            #|from orders
          ),
        )
      })
    })
  })
}

///|
/// Reads from `tcp` until smock closes the connection, ignoring what it
/// sends first, such as a TLS alert. Returns whether it closed in time.
async fn ends(tcp : @socket.Tcp) -> Bool {
  let closed = @async.with_timeout_opt(patience_ms, () => {
    while past_spurious_eagain(() => tcp.read_some()) is Some(_) {

    }
  })
  closed is Some(_)
}

///|
async test "a stalled or failed handshake affects only its own connection, and the idle timeout ends a stalled one" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--idle-timeout-ms",
          "1500",
          ..certs.args(),
        ],
        smock => {
          let address = @socket.Addr::parse("127.0.0.1:\{smock.tls_port}")
          // The first bytes of a TLS record, then nothing more.
          let since = @async.now()
          let stalled = @socket.Tcp::connect(address)
          defer stalled.close()
          stalled.write(b"\x16\x03\x01\x02\x00\x01")
          // Plain HTTP on the TLS port: the handshake fails.
          let failed = @socket.Tcp::connect(address)
          defer failed.close()
          failed.write(get_user)
          let out = [
            "the failed handshake's connection is closed: \{ends(failed)}",
            "HTTPS meanwhile: " +
            status_line(smock.exchange(Tls(certs), get_user)),
            "HTTP meanwhile: " + status_line(smock.exchange(Plain, get_user)),
          ]
          let stalled_closed = ends(stalled)
          let elapsed = @async.now() - since
          out.push(
            "the stalled handshake's connection is closed after the idle timeout: \{stalled_closed && elapsed >= 1500}",
          )
          inspect(
            out.join("\n"),
            content=(
              #|the failed handshake's connection is closed: true
              #|HTTPS meanwhile: HTTP/1.1 200 OK
              #|HTTP meanwhile: HTTP/1.1 200 OK
              #|the stalled handshake's connection is closed after the idle timeout: true
            ),
          )
        },
      )
    })
  })
}
