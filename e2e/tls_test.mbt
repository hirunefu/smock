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
          tls=true,
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
          #|Connection: close
          #|Content-Length: 23
          #|
          #|{"id":1,"name":"Alice"}
          #|---
          #|ECDSA, same as on the plain port: true
          #|HTTP/1.1 200 OK
          #|Content-Type: application/json
          #|X-Source: smock
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
    let runs : Array[(Array[String], Map[String, String])] = [
      (["--tls-cert-file", certs.rsa_chain], Map([])),
      ([], { "SMOCK_TLS_KEY_FILE": certs.rsa_key }),
      (["--tls-cert-file", "", "--tls-key-file", certs.rsa_key], Map([])),
      (certs.args(cert=missing), Map([])),
      (certs.args(key=missing), Map([])),
      (certs.args(cert=certs.dir), Map([])),
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
        hide_dir("status \{stopped.status}\n\{entries(stopped.logs)}", certs),
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
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/missing.pem","key_file":"$CERTS/rsa-key.pem","error":"cannot read the certificate file: no such file"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-chain.pem","key_file":"$CERTS/missing.pem","error":"cannot read the key file: no such file"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS","key_file":"$CERTS/rsa-key.pem","error":"cannot read the certificate file: is a directory"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/notes.txt","key_file":"$CERTS/rsa-key.pem","error":"certificate file: no PEM certificate found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-key.pem","key_file":"$CERTS/rsa-key.pem","error":"certificate file: no PEM certificate found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-chain.pem","key_file":"$CERTS/notes.txt","error":"key file: no PEM private key found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-chain.pem","key_file":"$CERTS/rsa-chain.pem","error":"key file: no PEM private key found"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-chain.pem","key_file":"$CERTS/other-key.pem","error":"the private key does not match the leaf certificate"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/rsa-chain.pem","key_file":"$CERTS/ecdsa-key.pem","error":"the private key does not match the leaf certificate"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","cert_file":"$CERTS/ecdsa-chain.pem","key_file":"$CERTS/rsa-key.pem","error":"the private key does not match the leaf certificate"}
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
      tls=true,
      smock => {
        let response = smock.exchange(Tls(certs), get_user)
        inspect(response.has_prefix("HTTP/1.1 404 Not Found"), content="true")
      },
    )
    inspect(
      hide_dir(entries(stopped.logs), certs),
      content=(
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*"}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","cert_file":"$CERTS/ecdsa-chain.pem","key_file":"$CERTS/ecdsa-key.pem"}
      ),
    )
  })
}

///|
/// Runs `openssl s_client` against the TLS port with `options`, trusting
/// only the test root CA, sends `request` once the handshake is done, and
/// returns three lines of what it printed: what ALPN selected, the
/// certificate verification result and the response's status line.
async fn Smock::s_client(
  self : Smock,
  certs : Certificates,
  options : Array[String],
  request : String,
) -> String {
  guard self.tls_port is Some(port) else {
    fail("the test did not wait for the TLS port")
  }
  write(certs.dir, "request.txt", request)
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(
      "openssl",
      [
        "s_client",
        "-connect",
        "127.0.0.1:\{port}",
        "-CAfile",
        certs.ca,
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
  [
    "status \{status}",
    first(["ALPN protocol:", "No ALPN negotiated"]),
    first(["Verify return code:"]),
    first(["HTTP/"]),
  ].join("\n")
}

///|
async test "ALPN: a client offering h2 and http/1.1 gets http/1.1, and a client that sends no ALPN is served" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", ..certs.args()],
        tls=true,
        smock => {
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
        },
      )
    })
  })
}

///|
async test "SNI never chooses the Mock: whatever name the client sends by SNI, the request is answered as on the plain port" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", ..certs.args()],
        tls=true,
        smock => {
          let plain = smock.exchange(Plain, get_user)
          let out = []
          for name in ["localhost", "orders.example"] {
            out.push(
              "SNI \{name}:\n" +
              smock.s_client(certs, ["-servername", name], get_user),
            )
          }
          inspect(
            "plain port:\n" +
            plain.split("\n").collect()[0].to_owned() +
            "\n---\n" +
            out.join("\n---\n"),
            content=(
              #|plain port:
              #|HTTP/1.1 200 OK
              #|---
              #|SNI localhost:
              #|status 0
              #|No ALPN negotiated
              #|Verify return code: 0 (ok)
              #|HTTP/1.1 200 OK
              #|---
              #|SNI orders.example:
              #|status 0
              #|No ALPN negotiated
              #|Verify return code: 0 (ok)
              #|HTTP/1.1 200 OK
            ),
          )
        },
      )
    })
  })
}

///|
/// Reads from `tcp` until smock closes the connection, ignoring what it
/// sends first, such as a TLS alert. Returns whether it closed in time.
async fn ends(tcp : @socket.Tcp) -> Bool {
  let closed = @async.with_timeout_opt(patience_ms, () => {
    while tcp.read_some() is Some(_) {

    }
  })
  closed is Some(_)
}

///|
/// The status line of a response.
fn status_line(response : String) -> String {
  response.split("\n").collect()[0].to_owned()
}

///|
async test "a stalled or failed handshake affects only its own connection" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        ["--dir", dir, "--port", "0", ..certs.args()],
        tls=true,
        smock => {
          let tls_port = smock.tls_port.unwrap()
          let address = @socket.Addr::parse("127.0.0.1:\{tls_port}")
          // The first bytes of a TLS record, then nothing more.
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
          inspect(
            out.join("\n"),
            content=(
              #|the failed handshake's connection is closed: true
              #|HTTPS meanwhile: HTTP/1.1 200 OK
              #|HTTP meanwhile: HTTP/1.1 200 OK
            ),
          )
        },
      )
    })
  })
}
