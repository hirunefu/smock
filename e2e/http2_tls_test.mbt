// Seam 2 tests of HTTP/2 on the TLS port by ALPN (h2): which protocol a
// connection gets, what each port says it serves, and requests over h2,
// which go through the connection's one writer like every TLS record. The
// clients are the OpenSSL bindings' client side, which offers ALPN.

///|
async test "each listening entry names the protocols its port serves: http/1.1 and h2c on the plain port, h2 and http/1.1 on the TLS port, http/1.1 on the admin port" {
  with_certificates(certs => {
    let stopped = with_smock(["--port", "0", ..certs.args()], _ => ())
    inspect(
      log_entries(
        stopped.logs.filter(line => line.contains("\"msg\":\"listening\"")),
      ),
      content=(
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*","protocols":["http/1.1"]}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*","protocols":["http/1.1","h2c"]}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","protocols":["h2","http/1.1"],"certFile":"*/rsa-chain.pem","keyFile":"*/rsa-key.pem"}
      ),
    )
  })
}

///|
/// What smock sent until it closed the connection, as text, with `\r\n`
/// shown as `\n` and the current Date masked (`mask_date`).
fn shown_text(received : Bytes) -> String {
  mask_date(@utf8.decode_lossy(received).replace_all(old="\r\n", new="\n"))
}

///|
async test "the TLS port never looks for the preface: on a connection that negotiated http/1.1, or no ALPN, the preface is HTTP/1.1 and gets 505" {
  with_certificates(certs => {
    let _ = with_smock(["--port", "0", ..certs.args()], smock => {
      let out = []
      for offer in [["http/1.1"], []] {
        let tls = smock.tls(alpn=offer)
        defer tls.close()
        tls.write(@http2.preface)
        out.push("ALPN \{tls.protocol()}:\n\{shown_text(tls.read_all())}")
      }
      inspect(
        out.join("\n---\n"),
        content=(
          #|ALPN http/1.1:
          #|HTTP/1.1 505 HTTP Version Not Supported
          #|Date: <now>
          #|Connection: close
          #|Content-Length: 0
          #|
          #|
          #|---
          #|ALPN none:
          #|HTTP/1.1 505 HTTP Version Not Supported
          #|Date: <now>
          #|Connection: close
          #|Content-Length: 0
          #|
          #|
        ),
      )
    })
  })
}

///|
async test "h2 on the TLS port: requests on one connection are answered, a delayed stream does not hold a fast one, and each is in the Journal as HTTP/2" {
  with_definitions([("m.json", delays)], dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let client = smock.h2()
        defer client.close()
        let out = []
        for path in ["/fast", "/fast"] {
          out.push(client.request("GET", path, authority="localhost").render())
        }
        let start = @async.now()
        let slow = client.send("GET", "/slow", authority="localhost")
        let fast = client.send("GET", "/fast?after=slow", authority="localhost")
        let fast_response = client.response(fast)
        let fast_ms = @async.now() - start
        let slow_response = client.response(slow)
        let slow_ms = @async.now() - start
        out.push("fast answered during the delay: \{fast_ms < 1000}")
        out.push("delayed answered after at least 1000 ms: \{slow_ms >= 1000}")
        out.push(fast_response.render())
        out.push(slow_response.render())
        let (status, journal) = smock.journal()
        guard journal is Object({ "entries": Array(entries), .. }) else {
          fail("no entries: \{journal.stringify()}")
        }
        out.push("journal: \{status}, \{entries.length()} entries")
        out.push(journal_shown(entries[entries.length() - 1]).stringify())
        inspect(
          out.join("\n---\n"),
          content=(
            #|200
            #|smock-mock: m; via=default
            #|date: <now>
            #|content-length: 4
            #|
            #|fast
            #|---
            #|200
            #|smock-mock: m; via=default
            #|date: <now>
            #|content-length: 4
            #|
            #|fast
            #|---
            #|fast answered during the delay: true
            #|---
            #|delayed answered after at least 1000 ms: true
            #|---
            #|200
            #|smock-mock: m; via=default
            #|date: <now>
            #|content-length: 4
            #|
            #|fast
            #|---
            #|200
            #|smock-mock: m; via=default
            #|date: <now>
            #|content-length: 4
            #|
            #|slow
            #|---
            #|journal: 200, 4 entries
            #|---
            #|{"seq":4,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"localhost","mock":"m","viaDefault":true,"digest":"<digest>","request":{"method":"GET","target":"/slow","version":"HTTP/2","headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false}},"stub":"slow","stubSource":"file","scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null,"status":200,"fault":null,"templateError":null}
          ),
        )
      })
    })
  })
}

///|
async test "h2 on the TLS port with the self-signed certificate, and with a Mock's own certificate chosen by SNI" {
  with_definitions(users_and_orders, dir => {
    with_pair(@testcerts.users_chain, @testcerts.users_key, users_dir => {
      with_scratch(scratch => {
        let _ = with_smock(
          [
            "--dir",
            dir,
            "--port",
            "0",
            "--tls-mock-certs",
            mock_certs([("users", users_dir)]),
          ],
          smock => {
            let presented = smock.presented_certificate(scratch)
            let self_signed = @fs.read_file(presented.file).text()
            let out = []
            let cases = [
              (
                "self-signed, SNI orders.example.com", "orders.example.com", self_signed,
              ),
              (
                "users' own, SNI users.example.com", "users.example.com", @testcerts.root_ca,
              ),
            ]
            for case in cases {
              let (label, name, trusted) = case
              let client = smock.h2(server_name=name, trusted~)
              defer client.close()
              let response = client.request("GET", "/x", authority=name)
              out.push(
                "\{label}: \{response.status} \{@utf8.decode_lossy(response.body)}",
              )
            }
            inspect(
              out.join(""),
              content=(
                #|self-signed, SNI orders.example.com: 200 from orders
                #|users' own, SNI users.example.com: 200 from users
                #|
              ),
            )
          },
        )
      })
    })
  })
}

///|
async test "SNI only chooses the certificate: streams of one TLS connection for several Mock Hosts each reach their own Host's Mock, and smock never answers 421" {
  with_definitions(users_and_orders, dir => {
    with_certificates(certs => {
      with_pair(@testcerts.users_chain, @testcerts.users_key, users_dir => {
        let _ = with_smock(
          [
            "--dir",
            dir,
            "--port",
            "0",
            "--tls-mock-certs",
            mock_certs([("users", users_dir)]),
            ..certs.args(),
          ],
          smock => {
            let out = []
            for sni in ["localhost", "users.example.com"] {
              let client = smock.h2(server_name=sni)
              defer client.close()
              let streams = []
              for
                host in [
                  "users.example.com", "orders.example.com", "users.example.com",
                ] {
                streams.push((host, client.send("GET", "/x", authority=host)))
              }
              for stream in streams {
                let (host, id) = stream
                let response = client.response(id)
                out.push(
                  "SNI \{sni}, :authority \{host}: \{response.status} \{@utf8.decode_lossy(response.body)}",
                )
              }
            }
            inspect(
              out.join(""),
              content=(
                #|SNI localhost, :authority users.example.com: 200 from users
                #|SNI localhost, :authority orders.example.com: 200 from orders
                #|SNI localhost, :authority users.example.com: 200 from users
                #|SNI users.example.com, :authority users.example.com: 200 from users
                #|SNI users.example.com, :authority orders.example.com: 200 from orders
                #|SNI users.example.com, :authority users.example.com: 200 from users
                #|
              ),
            )
          },
        )
      })
    })
  })
}

///|
async test "h2 on the TLS port: delayed responses queued at once, while the client reads nothing, sends PINGs and asks for a key update, all go out through the connection's one writer, the key update's answer first" {
  with_definitions([("m.json", big_delayed())], dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let raw = smock.raw_h2(settings=false, tls=true)
        defer raw.close()
        guard raw.wire is Encrypted(tls) else { fail("not over TLS") }
        // Windows wide open, so that each body fits them and is queued whole
        // once its delay is over.
        raw.send([
          Settings(params=[(0x4, 0x7fffffff)], ack=false),
          WindowUpdate(stream_id=0, increment=0x7fffffff - 65535),
        ])
        let streams = 32
        let requests = []
        for i in 0..<streams {
          requests.push(raw.get(2 * i + 1, "/big"))
        }
        raw.send(requests)
        let ping : @http2.Frame = Ping(
          payload=b"\x00\x00\x00\x00\x00\x00\x00\x01",
          ack=false,
        )
        // During the delays: smock's next write answers the key update.
        tls.tls.update_keys()
        raw.send([ping])
        // The delays end together, and the responses fill the socket long
        // before the client reads; the reader still reads the PINGs sent
        // meanwhile, while a task writes.
        @async.sleep(600)
        raw.send([ping, ping])
        @async.sleep(400)
        let received = Map([])
        let ended = []
        let others = []
        let mut acks = 0
        while ended.length() < streams || acks < 3 {
          guard raw.read_frame() is Some(frame) else {
            others.push("closed")
            break
          }
          match frame {
            Data(stream_id~, data~, end_stream~, ..) => {
              received[stream_id] = received.get(stream_id).unwrap_or(0) +
                data.length()
              if end_stream {
                ended.push(stream_id)
              }
            }
            Ping(ack=true, ..) => acks += 1
            Headers(..) | Settings(..) => ()
            _ => others.push(raw.render_frame(frame))
          }
        }
        let whole = ended.filter(stream => received.get(stream) == Some(65536))
        inspect(
          [
            "streams answered in full: \{whole.length()}",
            "PINGs acknowledged: \{acks}",
            ..others,
          ].join("\n"),
          content=(
            #|streams answered in full: 32
            #|PINGs acknowledged: 3
          ),
        )
      })
    })
  })
}
