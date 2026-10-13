// The bindings' own tests. They do no I/O: a client and a server
// Connection run in memory, and the tests carry the bytes each one writes to
// the other. scripts/test-openssl-asan.sh runs them under AddressSanitizer and
// LeakSanitizer.

///|
fn bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// A server configuration from the fixtures, offering `http/1.1` by ALPN.
fn server_config(chain : String, key : String) -> @openssl.ServerConfig raise {
  @openssl.ServerConfig(
    certificate_chain=bytes(chain),
    private_key=bytes(key),
    alpn=["http/1.1"],
  )
}

///|
/// A client that trusts only the test root CA and checks the server's
/// certificate for `localhost`.
fn client(alpn? : Array[String] = []) -> @openssl.Connection raise {
  @openssl.ClientConfig(trusted=bytes(@testcerts.root_ca), alpn~).connect(
    server_name="localhost",
  )
}

///|
/// Carries the bytes each side writes to the other until both have
/// finished the handshake.
fn handshake(
  client : @openssl.Connection,
  server : @openssl.Connection,
) -> Unit raise {
  for _ in 0..<10 {
    let client_done = client.handshake()
    server.receive(client.take_output())
    let server_done = server.handshake()
    client.receive(server.take_output())
    if client_done && server_done {
      return
    }
  }
  fail("the handshake did not finish")
}

///|
/// Sends `text` from `from` to `to` and returns what `to` reads.
fn send(
  from : @openssl.Connection,
  to : @openssl.Connection,
  text : String,
) -> String raise {
  from.write(bytes(text))
  to.receive(from.take_output())
  let buf = FixedArray::make(1024, b'\x00')
  let out = StringBuilder()
  for ;; {
    match to.read(buf, offset=0, max_len=buf.length()) {
      Data(n) =>
        out.write_string(
          @utf8.decode_lossy(buf.unsafe_reinterpret_as_bytes()[:n]),
        )
      NeedInput | Closed => break
    }
  }
  out.to_string()
}

///|
test "a client that trusts only the root CA completes a handshake with a server presenting an RSA leaf and its intermediate" {
  let server = server_config(@testcerts.rsa_chain, @testcerts.rsa_key).accept()
  let client = client()
  handshake(client, server)
  inspect(
    send(client, server, "ping") + " " + send(server, client, "pong"),
    content="ping pong",
  )
}

///|
test "an ECDSA leaf and its intermediate work the same way" {
  let server = server_config(@testcerts.ecdsa_chain, @testcerts.ecdsa_key).accept()
  let client = client()
  handshake(client, server)
  inspect(
    send(client, server, "ping") + " " + send(server, client, "pong"),
    content="ping pong",
  )
}

///|
/// The first certificate of a PEM chain.
fn leaf_of(chain : String) -> String {
  let end = "-----END CERTIFICATE-----"
  chain[:chain.find(end).unwrap() + end.length()].to_owned()
}

///|
test "the intermediate sent with the leaf is what lets the client verify it" {
  // The same leaf without its intermediate: the client, which trusts only
  // the root CA, cannot build a path to it.
  let server = server_config(leaf_of(@testcerts.rsa_chain), @testcerts.rsa_key).accept()
  let client = client()
  let result = try handshake(client, server) catch {
    @openssl.Failed(reason) => "failed: \{reason}"
    err => "other: \{err}"
  } noraise {
    _ => "handshake done"
  }
  inspect(result, content="failed: certificate verify failed")
}

///|
/// What loading a server configuration from `chain` and `key` gives.
fn load(chain : String, key : String) -> String {
  let config = server_config(chain, key) catch { err => return describe(err) }
  ignore(config)
  "loaded"
}

///|
fn describe(err : Error) -> String {
  match err {
    @openssl.InvalidCertificate(reason) => "invalid certificate: \{reason}"
    @openssl.InvalidPrivateKey(reason) => "invalid private key: \{reason}"
    @openssl.KeyMismatch => "key mismatch"
    @openssl.Failed(reason) => "failed: \{reason}"
    err => "other: \{err}"
  }
}

///|
test "a refused configuration's message says why, without naming the file it was loading" {
  let message = (chain : String, key : String) => {
    try
      @openssl.ServerConfig(
        certificate_chain=bytes(chain),
        private_key=bytes(key),
        alpn=["http/1.1"],
      )
    catch {
      err => err.message()
    } noraise {
      _ => "loaded"
    }
  }
  inspect(
    [
      message(@testcerts.rsa_key, @testcerts.rsa_key),
      message(@testcerts.rsa_chain, @testcerts.rsa_chain),
      message(@testcerts.rsa_chain, @testcerts.ecdsa_key),
    ].join("\n"),
    content=(
      #|no PEM certificate found
      #|no PEM private key found
      #|the private key does not match the leaf certificate
    ),
  )
}

///|
test "a configuration that cannot be used is refused with the reason" {
  let rsa_leaf = leaf_of(@testcerts.rsa_chain)
  let out = [
    load(@testcerts.rsa_chain, @testcerts.rsa_key),
    load("", @testcerts.rsa_key),
    load(@testcerts.rsa_key, @testcerts.rsa_key),
    load(
      "-----BEGIN CERTIFICATE-----\nnot base64\n-----END CERTIFICATE-----\n", @testcerts.rsa_key,
    ),
    load(@testcerts.rsa_chain, ""),
    load(@testcerts.rsa_chain, rsa_leaf),
    load(
      @testcerts.rsa_chain, "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
    ),
    load(
      @testcerts.rsa_chain, "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n",
    ),
    load(@testcerts.rsa_chain, @testcerts.other_rsa_key),
    load(@testcerts.rsa_chain, @testcerts.ecdsa_key),
    load(@testcerts.ecdsa_chain, @testcerts.rsa_key),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|loaded
      #|invalid certificate: no PEM certificate found
      #|invalid certificate: no PEM certificate found
      #|invalid certificate: cannot parse a PEM certificate: bad base64 decode
      #|invalid private key: no PEM private key found
      #|invalid private key: no PEM private key found
      #|invalid private key: cannot parse the PEM private key
      #|invalid private key: encrypted private keys are not supported
      #|key mismatch
      #|key mismatch
      #|key mismatch
    ),
  )
}

///|
test "ALPN: a server accepting http/1.1 picks it from h2 and http/1.1, serves a client without ALPN, and refuses a client offering only h2" {
  let config = server_config(@testcerts.rsa_chain, @testcerts.rsa_key)
  let out = []
  for offer in [["h2", "http/1.1"], [], ["h2"]] {
    let server = config.accept()
    let client = client(alpn=offer)
    let result = try handshake(client, server) catch {
      err => describe(err)
    } noraise {
      _ =>
        "client \{client.alpn_protocol().unwrap_or("none")}, server \{server.alpn_protocol().unwrap_or("none")}"
    }
    out.push("offers [\{offer.join(", ")}]: \{result}")
  }
  inspect(
    out.join("\n"),
    content=(
      #|offers [h2, http/1.1]: client http/1.1, server http/1.1
      #|offers []: client none, server none
      #|offers [h2]: failed: no application protocol
    ),
  )
}

///|
test "a close_notify from the peer reads as Closed" {
  let server = server_config(@testcerts.rsa_chain, @testcerts.rsa_key).accept()
  let client = client()
  handshake(client, server)
  client.shutdown()
  server.receive(client.take_output())
  let buf = FixedArray::make(16, b'\x00')
  debug_inspect(server.read(buf, offset=0, max_len=16), content="Closed")
}

///|
/// Generates a self-signed certificate for `names`, valid for a year.
fn self_signed(names : Array[String]) -> @openssl.SelfSigned raise {
  @openssl.SelfSigned::generate(names, days=365)
}

///|
/// Whether a client that trusts only `trusted` completes a handshake with a
/// server presenting `config`, checking its certificate for `name`.
fn verify_for(
  config : @openssl.ServerConfig,
  trusted : Bytes,
  name : String,
) -> String {
  let result = try {
    let client = @openssl.ClientConfig(trusted~).connect(server_name=name)
    handshake(client, config.accept())
  } catch {
    err => describe(err)
  } noraise {
    _ => "verified"
  }
  "\{name}: \{result}"
}

///|
test "a generated self-signed certificate serves TLS, and a client that trusts it verifies it for each of its names, IP addresses included, and for no other name" {
  let generated = self_signed([
    "localhost", "127.0.0.1", "::1", "users.example.com",
  ])
  let config = @openssl.ServerConfig(
    certificate_chain=generated.certificate,
    private_key=generated.private_key,
    alpn=["http/1.1"],
  )
  let names = [
    "localhost", "127.0.0.1", "::1", "users.example.com", "orders.example.com", "127.0.0.2",
    "::2",
  ]
  inspect(
    names
    .map(name => verify_for(config, generated.certificate, name))
    .join("\n"),
    content=(
      #|localhost: verified
      #|127.0.0.1: verified
      #|::1: verified
      #|users.example.com: verified
      #|orders.example.com: failed: certificate verify failed
      #|127.0.0.2: failed: certificate verify failed
      #|::2: failed: certificate verify failed
    ),
  )
}

///|
/// `fingerprint` with each hex digit shown as `h`, if it has only hex
/// digits and colons.
fn fingerprint_shape(fingerprint : String) -> String {
  fingerprint
  .iter()
  .map(c => {
    if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') {
      'h'
    } else {
      c
    }
  })
  .collect()
  |> String::from_array
}

///|
test "each generated certificate has a new key and its own SHA-256 fingerprint" {
  let first = self_signed(["localhost"])
  let second = self_signed(["localhost"])
  let out = [
    "fingerprint: " + fingerprint_shape(first.sha256_fingerprint),
    "same fingerprint: \{first.sha256_fingerprint == second.sha256_fingerprint}",
    "first certificate with the second key: " +
    load_bytes(first.certificate, second.private_key),
    "first certificate with its own key: " +
    load_bytes(first.certificate, first.private_key),
  ]
  inspect(
    out.join("\n"),
    content=(
      #|fingerprint: hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh:hh
      #|same fingerprint: false
      #|first certificate with the second key: key mismatch
      #|first certificate with its own key: loaded
    ),
  )
}

///|
/// What loading a server configuration from PEM bytes gives.
fn load_bytes(chain : Bytes, key : Bytes) -> String {
  let config = @openssl.ServerConfig(certificate_chain=chain, private_key=key, alpn=[
    "http/1.1",
  ]) catch {
    err => return describe(err)
  }
  ignore(config)
  "loaded"
}

///|
test "a self-signed certificate needs names, none of them empty" {
  let out = [[], ["localhost", ""], ["a\u{0}b"]].map(names => {
    let generated = self_signed(names) catch { err => return describe(err) }
    ignore(generated)
    "generated"
  })
  inspect(
    out.join("\n"),
    content=(
      #|failed: a self-signed certificate needs at least one name
      #|failed: invalid name "" for a certificate
      #|failed: invalid name "a\u{00}b" for a certificate
    ),
  )
}
