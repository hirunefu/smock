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
