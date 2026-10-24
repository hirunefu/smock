// Seam 2 tests of --tls-http2 with every kind of certificate, reloads
// included, and of h2 over TLS 1.2, where smock declines h2 over a suite
// that RFC 9113 prohibits. The ALPN clients are the OpenSSL bindings' client
// side (`Smock::alpn_offer`), and `openssl s_client` for TLS 1.2.

///|
/// What a client offering `h2` and `http/1.1`, and one offering `h2` alone,
/// each get from a handshake for `server_name`, trusting only the PEM
/// certificates in `trusted`, then `GET /x` for that Host over the protocol
/// ALPN selected.
async fn Smock::offers(
  self : Smock,
  server_name : String,
  trusted~ : String = @testcerts.root_ca,
) -> String {
  let both = self.alpn_offer(
    ["h2", "http/1.1"],
    server_name~,
    trusted~,
    path="/x",
  )
  let alone = self.alpn_offer(["h2"], server_name~, trusted~, path="/x")
  "offers [h2, http/1.1]: \{both}; offers [h2]: \{alone}"
}

///|
async test "--tls-http2 holds for the certificate files and for a Mock's own certificate, and still holds after both pairs are reloaded" {
  let mocks = mocks_with_stubs([
    ("local", "localhost"),
    ("users", "users.example.com"),
  ])
  with_definitions([("mocks.json", mocks)], dir => {
    let out = []
    for flag in ["on", "off"] {
      with_pair(@testcerts.rsa_chain, @testcerts.rsa_key, tls_dir => {
        with_pair(@testcerts.users_chain, @testcerts.users_key, users_dir => {
          let _ = with_smock(
            [
              "--dir",
              dir,
              "--port",
              "0",
              "--tls-http2",
              flag,
              "--tls-cert-file",
              "\{tls_dir}/tls.crt",
              "--tls-key-file",
              "\{tls_dir}/tls.key",
              "--tls-mock-certs",
              mock_certs([("users", users_dir)]),
            ],
            smock => {
              out.push("--tls-http2 \{flag}:")
              out.push("certificate files: \{smock.offers("localhost")}")
              out.push("users' own: \{smock.offers("users.example.com")}")
              write(tls_dir, "tls.crt", @testcerts.ecdsa_chain + "\n")
              write(tls_dir, "tls.key", @testcerts.ecdsa_key + "\n")
              write(users_dir, "tls.crt", @testcerts.users_renewed_chain + "\n")
              write(users_dir, "tls.key", @testcerts.users_renewed_key + "\n")
              out.push(smock.certificate_entries(2))
              out.push(
                "certificate files, reloaded: \{smock.offers("localhost")}",
              )
              out.push(
                "users' own, reloaded: \{smock.offers("users.example.com")}",
              )
            },
          )
        })
      })
    }
    inspect(
      out.join("\n"),
      content=(
        #|--tls-http2 on:
        #|certificate files: offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
        #|users' own: offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
        #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
        #|{"level":"info","msg":"TLS certificate reloaded","mock":"users","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2124-07-01T00:00:00.000Z"}
        #|certificate files, reloaded: offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
        #|users' own, reloaded: offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
        #|--tls-http2 off:
        #|certificate files: offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
        #|users' own: offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
        #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
        #|{"level":"info","msg":"TLS certificate reloaded","mock":"users","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2124-07-01T00:00:00.000Z"}
        #|certificate files, reloaded: offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
        #|users' own, reloaded: offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
      ),
    )
  })
}

///|
async test "--tls-http2 holds for the self-signed certificate, and for the one generated again when a reload adds a Mock with a new Host" {
  let users = ("users", "users.example.com")
  let orders = ("orders", "orders.example.com")
  let out = []
  for flag in ["on", "off"] {
    with_definitions([("mocks.json", mocks_with_stubs([users]))], defs => {
      with_scratch(scratch => {
        let _ = with_smock(
          ["--dir", defs, "--port", "0", "--tls-http2", flag],
          smock => {
            out.push("--tls-http2 \{flag}:")
            let first = smock.presented_certificate(scratch)
            let trusted = @fs.read_file(first.file).text()
            out.push(
              "self-signed: \{smock.offers("users.example.com", trusted~)}",
            )
            let status = smock.status()
            write(defs, "mocks.json", mocks_with_stubs([users, orders]))
            let _ = smock.reloaded(status)
            let again = smock.presented_certificate(scratch)
            let trusted = @fs.read_file(again.file).text()
            out.push(
              "generated again: \{again.fingerprint != first.fingerprint}, \{smock.offers("orders.example.com", trusted~)}",
            )
          },
        )
      })
    })
  }
  inspect(
    out.join("\n"),
    content=(
      #|--tls-http2 on:
      #|self-signed: offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
      #|generated again: true, offers [h2, http/1.1]: ALPN h2, HTTP/2 200; offers [h2]: ALPN h2, HTTP/2 200
      #|--tls-http2 off:
      #|self-signed: offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
      #|generated again: true, offers [h2, http/1.1]: ALPN http/1.1, HTTP/1.1 200 OK; offers [h2]: handshake failed: tlsv1 alert no application protocol
    ),
  )
}

///|
async test "over TLS 1.2, ALPN skips h2 when the suite is one RFC 9113 prohibits: with only a CBC suite, h2 and http/1.1 get http/1.1 and h2 alone fails; the mandatory ECDHE-RSA-AES128-GCM-SHA256 with P-256 gets h2" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let cbc = ["-cipher", "ECDHE-RSA-AES128-SHA256"]
        let mandatory = [
          "-cipher", "ECDHE-RSA-AES128-GCM-SHA256", "-groups", "P-256",
        ]
        let suite = ["New, "]
        let alpn = ["ALPN protocol:", "No ALPN negotiated"]
        let cases = [
          (
            "only a CBC suite, offering h2 and http/1.1",
            [..cbc, "-alpn", "h2,http/1.1"],
            [suite, alpn, ["HTTP/"]],
          ),
          (
            "only a CBC suite, offering h2 alone",
            [..cbc, "-alpn", "h2"],
            [suite, alpn],
          ),
          (
            "the mandatory suite with P-256, offering h2 and http/1.1",
            [..mandatory, "-alpn", "h2,http/1.1"],
            [suite, alpn],
          ),
        ]
        let out = []
        for case in cases {
          let (label, options, show) = case
          out.push(
            "\{label}:\n" +
            smock.s_client(certs, ["-tls1_2", ..options], get_user, show~),
          )
        }
        inspect(
          out.join("\n---\n"),
          content=(
            #|only a CBC suite, offering h2 and http/1.1:
            #|status 0
            #|New, TLSv1.2, Cipher is ECDHE-RSA-AES128-SHA256
            #|ALPN protocol: http/1.1
            #|HTTP/1.1 200 OK
            #|---
            #|only a CBC suite, offering h2 alone:
            #|status 1
            #|New, (NONE), Cipher is (NONE)
            #|No ALPN negotiated
            #|---
            #|the mandatory suite with P-256, offering h2 and http/1.1:
            #|status 0
            #|New, TLSv1.2, Cipher is ECDHE-RSA-AES128-GCM-SHA256
            #|ALPN protocol: h2
          ),
        )
      })
    })
  })
}
