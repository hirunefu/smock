// Seam 2 tests of certificate rotation and per-Mock certificates by SNI.
// `openssl s_client` is the TLS client that shows which certificate smock
// presents: each test leaf has its own common name, such as smock-test-rsa,
// and its own expiry.

///|
/// The certificate expiry metric.
let expiry_metric : String = "smock_tls_certificate_expiry_timestamp_seconds"

///|
/// `GET /users/1` on a connection that stays open.
let keep_alive_get : String = "GET /users/1 HTTP/1.1\r\nHost: localhost\r\n\r\n"

///|
/// The common name of the leaf certificate smock presents to a handshake
/// that sends `sni` by SNI, or no SNI when `sni` is `None`. When the
/// handshake fails, what `openssl s_client` printed instead.
async fn Smock::presented(
  self : Smock,
  certs : Certificates,
  sni? : String,
) -> String {
  let options = match sni {
    Some(name) => ["-servername", name]
    None => ["-noservername"]
  }
  // OpenSSL 3.0 writes `subject=CN = name`, later versions
  // `subject=CN=name`.
  let out = self.s_client(certs, options, get_user, show=[["subject="]])
  guard out.strip_prefix("status 0\nsubject=") is Some(subject) else {
    return out
  }
  subject[subject.rev_find("=").unwrap_or(-1) + 1:].trim().to_owned()
}

///|
/// Whether a log line is about a TLS certificate.
fn is_certificate_entry(line : String) -> Bool {
  let entry = @json.parse(line) catch { _ => return false }
  entry is Object(fields) &&
  fields.get("msg") is Some(String(msg)) &&
  msg.contains("TLS certificate")
}

///|
/// Waits until smock has logged `count` entries about TLS certificates in
/// all, at most `within` milliseconds, and returns them as `log_entries`
/// shows them.
async fn Smock::certificate_entries(
  self : Smock,
  count : Int,
  within? : Int = reload_patience_ms,
) -> String {
  let logged = @async.with_timeout_opt(within, () => {
    for ;; {
      let lines = self.logs.filter(is_certificate_entry)
      if lines.length() >= count {
        break log_entries(lines)
      }
      @async.sleep(20)
    }
  })
  guard logged is Some(logged) else {
    fail(
      "fewer than \{count} entries about TLS certificates in time:\n\{self.logs.join("\n")}",
    )
  }
  logged
}

///|
/// Runs `f` with a new temporary directory that holds `tls.crt` and
/// `tls.key`: `chain` and `key`.
async fn with_pair(
  chain : String,
  key : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([("tls.crt", chain + "\n"), ("tls.key", key + "\n")], f)
}

///|
/// The flags that serve HTTPS with `tls.crt` and `tls.key` in `dir`.
fn Certificates::pair_args(self : Certificates, dir : String) -> Array[String] {
  self.args(cert="\{dir}/tls.crt", key="\{dir}/tls.key")
}

///|
async test "rewriting the certificate files rotates the certificate without a restart: new handshakes get the new one, an open connection carries on, and the expiry metric and one log line follow, with no log line per handshake" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      with_pair(@testcerts.rsa_chain, @testcerts.rsa_key, tls_dir => {
        let stopped = with_smock(
          ["--dir", dir, "--port", "0", ..certs.pair_args(tls_dir)],
          smock => {
            let open = smock.connect(over=Tls(certs))
            defer open.close()
            open.write(keep_alive_get)
            let first = status_line(read_response(open))
            let before = smock.presented(certs)
            let metric_before = smock.metric(expiry_metric)
            write(tls_dir, "tls.crt", @testcerts.ecdsa_chain + "\n")
            write(tls_dir, "tls.key", @testcerts.ecdsa_key + "\n")
            let logged = smock.certificate_entries(1)
            open.write(keep_alive_get)
            let second = status_line(read_response(open))
            inspect(
              (
                $|open connection: \{first}
                $|before: \{before}
                $|\{metric_before}
                $|\{logged}
                $|after: \{smock.presented(certs)}
                $|\{smock.metric(expiry_metric)}
                $|open connection after the rotation: \{second}
              ),
              content=(
                #|open connection: HTTP/1.1 200 OK
                #|before: smock-test-rsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
                #|after: smock-test-ecdsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4891363200
                #|open connection after the rotation: HTTP/1.1 200 OK
              ),
            )
          },
        )
        // Four handshakes, one rotation.
        inspect(
          log_entries(stopped.logs),
          content=(
            #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
            #|{"level":"info","msg":"random seed","seed":"*"}
            #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
            #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
            #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
            #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
            #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*","certFile":"*/tls.crt","keyFile":"*/tls.key"}
            #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
            #|{"level":"info","msg":"drain started","timeoutMs":20000}
            #|{"level":"info","msg":"drain ended","connectionsCut":0}
          ),
        )
      })
    })
  })
}

///|
/// Runs `f` with a new temporary directory laid out as a Kubernetes Secret
/// volume: `tls.crt` and `tls.key` are symlinks into `..data`, which points
/// at the version `..2026_10_13_01` that holds `chain` and `key`.
async fn with_secret(
  chain : String,
  key : String,
  f : async (String) -> Unit,
) -> Unit {
  with_definitions([], dir => {
    configmap_update(dir, "2026_10_13_01", [
      ("tls.crt", chain + "\n"),
      ("tls.key", key + "\n"),
    ])
    for name in ["tls.crt", "tls.key"] {
      @fs.symlink(target="..data/\{name}", "\{dir}/\{name}")
    }
    f(dir)
  })
}

///|
async test "a Secret-style update, which swaps the ..data symlink and keeps the visible file names, rotates the certificate" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      with_secret(@testcerts.rsa_chain, @testcerts.rsa_key, secret => {
        let _ = with_smock(
          ["--dir", dir, "--port", "0", ..certs.pair_args(secret)],
          smock => {
            let before = smock.presented(certs)
            configmap_update(
              secret,
              "2026_10_13_02",
              [
                ("tls.crt", @testcerts.ecdsa_chain + "\n"),
                ("tls.key", @testcerts.ecdsa_key + "\n"),
              ],
              replaces="2026_10_13_01",
            )
            let logged = smock.certificate_entries(1)
            inspect(
              (
                $|before: \{before}
                $|\{logged}
                $|after: \{smock.presented(certs)}
                $|\{smock.metric(expiry_metric)}
              ),
              content=(
                #|before: smock-test-rsa
                #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
                #|after: smock-test-ecdsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4891363200
              ),
            )
          },
        )
      })
    })
  })
}

///|
async test "a Secret-style update where no event reports it, behind symlinks that lead out of the certificate directory, is found by the next poll" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      with_secret(@testcerts.rsa_chain, @testcerts.rsa_key, secret => {
        with_definitions([], linked => {
          for name in ["tls.crt", "tls.key"] {
            @fs.symlink(target="\{secret}/\{name}", "\{linked}/\{name}")
          }
          // Older than the 2 s after which a poll trusts its stamp.
          @async.sleep(2500)
          let _ = with_smock(
            ["--dir", dir, "--port", "0", ..certs.pair_args(linked)],
            smock => {
              let before = smock.presented(certs)
              configmap_update(
                secret,
                "2026_10_13_02",
                [
                  ("tls.crt", @testcerts.ecdsa_chain + "\n"),
                  ("tls.key", @testcerts.ecdsa_key + "\n"),
                ],
                replaces="2026_10_13_01",
              )
              @async.sleep(1000)
              let within = smock.logs.filter(is_certificate_entry).length()
              let logged = smock.certificate_entries(1, within=poll_patience_ms)
              inspect(
                (
                  $|before: \{before}
                  $|entries within 1 s: \{within}
                  $|\{logged}
                  $|after: \{smock.presented(certs)}
                ),
                content=(
                  #|before: smock-test-rsa
                  #|entries within 1 s: 0
                  #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
                  #|after: smock-test-ecdsa
                ),
              )
            },
          )
        })
      })
    })
  })
}

///|
async test "a changed pair that cannot be used is not swapped in: smock keeps presenting the previous certificate and logs why, with the new expiry when the new certificate can be read" {
  with_definitions([("users.json", users)], dir => {
    with_certificates(certs => {
      with_pair(@testcerts.rsa_chain, @testcerts.rsa_key, tls_dir => {
        let _ = with_smock(
          ["--dir", dir, "--port", "0", ..certs.pair_args(tls_dir)],
          smock => {
            let steps : Array[(String, async () -> Unit)] = [
              (
                "a certificate file that is not PEM",
                () => write(tls_dir, "tls.crt", "not PEM\n"),
              ),
              (
                "a certificate the key does not belong to",
                () => write(tls_dir, "tls.crt", @testcerts.ecdsa_chain + "\n"),
              ),
              (
                "a key file that cannot be read",
                () => @fs.remove("\{tls_dir}/tls.key"),
              ),
              (
                "the key of the new certificate",
                () => write(tls_dir, "tls.key", @testcerts.ecdsa_key + "\n"),
              ),
            ]
            let out = []
            for i, step in steps {
              let (name, change) = step
              change()
              let logged = smock.certificate_entries(i + 1)
              let entry = logged.split("\n").last().unwrap().to_owned()
              out.push(
                (
                  $|\{name}:
                  $|\{entry}
                  $|presented: \{smock.presented(certs)}
                  $|\{smock.metric(expiry_metric)}
                ),
              )
            }
            inspect(
              out.join("\n"),
              content=(
                #|a certificate file that is not PEM:
                #|{"level":"error","msg":"TLS certificate reload failed","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":null,"error":"certificate file: no PEM certificate found"}
                #|presented: smock-test-rsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                #|a certificate the key does not belong to:
                #|{"level":"error","msg":"TLS certificate reload failed","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z","error":"the private key does not match the leaf certificate"}
                #|presented: smock-test-rsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                #|a key file that cannot be read:
                #|{"level":"error","msg":"TLS certificate reload failed","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":null,"error":"cannot read the key file: no such file"}
                #|presented: smock-test-rsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                #|the key of the new certificate:
                #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
                #|presented: smock-test-ecdsa
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4891363200
              ),
            )
          },
        )
      })
    })
  })
}

///|
/// The value of `--tls-mock-certs` that gives each Mock in `pairs` the
/// `tls.crt` and `tls.key` of its directory.
fn mock_certs(pairs : Array[(String, String)]) -> String {
  let mapping : Map[String, Json] = Map([])
  for pair in pairs {
    let (mock, dir) = pair
    mapping[mock] = {
      "certFile": Json::string("\{dir}/tls.crt"),
      "keyFile": Json::string("\{dir}/tls.key"),
    }
  }
  Json::object(mapping).stringify()
}

///|
/// What each handshake in `snis` gets, one line each: the SNI it sends,
/// or none, and the certificate presented.
async fn Smock::presented_by_sni(
  self : Smock,
  certs : Certificates,
  snis : Array[String?],
) -> String {
  let out = []
  for sni in snis {
    let presented = match sni {
      Some(name) => "SNI \{name}: \{self.presented(certs, sni=name)}"
      None => "no SNI: \{self.presented(certs)}"
    }
    out.push(presented)
  }
  out.join("\n")
}

///|
async test "SNI: a name that is a Host of a Mock with its own certificate gets that certificate, compared as Hosts are; a Host of another Mock, an unknown name and no SNI get the default certificate" {
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
            let presented = smock.presented_by_sni(certs, [
              Some("users.example.com"),
              Some("USERS.Example.COM."),
              Some("orders.example.com"),
              Some("unknown.example.com"),
              None,
            ])
            inspect(
              (
                $|\{presented}
                $|\{smock.metric(expiry_metric, help=true)}
              ),
              content=(
                #|SNI users.example.com: smock-test-users
                #|SNI USERS.Example.COM.: smock-test-users
                #|SNI orders.example.com: smock-test-rsa
                #|SNI unknown.example.com: smock-test-rsa
                #|no SNI: smock-test-rsa
                #|# HELP smock_tls_certificate_expiry_timestamp_seconds When each certificate the TLS port presents expires (its notAfter), in seconds since the Unix epoch, by the Mock it is for: mock="" for the default certificate.
                #|# TYPE smock_tls_certificate_expiry_timestamp_seconds gauge
                #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                #|smock_tls_certificate_expiry_timestamp_seconds{mock="users"} 4859740800
              ),
            )
          },
        )
      })
    })
  })
}

///|
/// What each handshake in `snis` gets, one line each, as a client that
/// does not verify the certificate sees it: the SNI it sends, or none, and
/// the common name of the certificate presented. `scratch` is a directory
/// for openssl's input.
async fn Smock::unverified_by_sni(
  self : Smock,
  scratch : String,
  snis : Array[String?],
) -> String {
  write(scratch, "empty.txt", "")
  let out = []
  for sni in snis {
    let (options, shown) = match sni {
      Some(name) => (["-servername", name], "SNI \{name}")
      None => (["-noservername"], "no SNI")
    }
    let (_, output) = run_openssl(
      ["s_client", "-connect", "127.0.0.1:\{self.tls_port}", ..options],
      stdin="\{scratch}/empty.txt",
    )
    // OpenSSL 3.0 writes `subject=CN = name`, later versions
    // `subject=CN=name`.
    let subject = line_after(output, "subject=")
    let name = subject[subject.rev_find("=").unwrap_or(-1) + 1:].trim()
    out.push("\{shown}: \{name}")
  }
  out.join("\n")
}

///|
async test "without default certificate files, a Mock's own certificate is chosen by SNI and rotates, and any other handshake gets the self-signed certificate for every Host" {
  with_definitions(users_and_orders, dir => {
    with_secret(@testcerts.users_chain, @testcerts.users_key, users_dir => {
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
            let snis = [
              Some("users.example.com"),
              Some("orders.example.com"),
              Some("unknown.example.com"),
              None,
            ]
            let before = smock.unverified_by_sni(scratch, snis)
            let names = smock.logs
              .filter(line => line.contains("self-signed certificate in use"))
              .map(line => {
                guard @json.parse(line) is Object({ "names": names, .. }) else {
                  line
                }
                names.stringify()
              })
            configmap_update(
              users_dir,
              "2026_10_13_02",
              [
                ("tls.crt", @testcerts.users_renewed_chain + "\n"),
                ("tls.key", @testcerts.users_renewed_key + "\n"),
              ],
              replaces="2026_10_13_01",
            )
            let logged = smock.certificate_entries(1)
            inspect(
              (
                $|\{before}
                $|self-signed names: \{names.join(" | ")}
                $|\{logged}
                $|\{smock.unverified_by_sni(scratch, snis)}
              ),
              content=(
                #|SNI users.example.com: smock-test-users
                #|SNI orders.example.com: smock self-signed
                #|SNI unknown.example.com: smock self-signed
                #|no SNI: smock self-signed
                #|self-signed names: ["localhost","127.0.0.1","::1","orders.example.com","users.example.com"]
                #|{"level":"info","msg":"TLS certificate reloaded","mock":"users","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2124-07-01T00:00:00.000Z"}
                #|SNI users.example.com: smock-test-users-renewed
                #|SNI orders.example.com: smock self-signed
                #|SNI unknown.example.com: smock self-signed
                #|no SNI: smock self-signed
              ),
            )
          },
        )
      })
    })
  })
}

///|
async test "SNI never chooses the Mock: a request whose SNI gets one Mock's certificate and whose Host header names another Mock is answered by the Mock of its Host header" {
  with_definitions(users_and_orders, dir => {
    with_certificates(certs => {
      with_pair(@testcerts.users_chain, @testcerts.users_key, users_dir => {
        let _ = with_smock(
          ["--dir", dir, "--port", "0", ..certs.args()],
          env={ "SMOCK_TLS_MOCK_CERTS": mock_certs([("users", users_dir)]) },
          smock => {
            let request = "GET /x HTTP/1.1\r\nHost: orders.example.com\r\nConnection: close\r\n\r\n"
            inspect(
              smock
              .s_client(certs, ["-servername", "users.example.com"], request, show=[
                ["subject="],
                ["HTTP/"],
                ["from "],
              ])
              .replace_all(old="CN = ", new="CN="),
              content=(
                #|status 0
                #|subject=CN=smock-test-users
                #|HTTP/1.1 200 OK
                #|from orders
              ),
            )
          },
        )
      })
    })
  })
}

///|
async test "a Mock's certificate rotates the same way as the default certificate, and in the same process one pair rotates by a Secret-style update and the other by rewriting its files, each changing only its own handshakes, metric series and log entry" {
  with_definitions(users_and_orders, dir => {
    with_certificates(certs => {
      with_pair(@testcerts.rsa_chain, @testcerts.rsa_key, default_dir => {
        with_secret(@testcerts.users_chain, @testcerts.users_key, users_dir => {
          let _ = with_smock(
            [
              "--dir",
              dir,
              "--port",
              "0",
              "--tls-mock-certs",
              mock_certs([("users", users_dir)]),
              ..certs.pair_args(default_dir),
            ],
            smock => {
              let snis = [Some("users.example.com"), None]
              let steps : Array[(String, async () -> Unit)] = [
                (
                  "a Secret-style update of the Mock's pair",
                  () => {
                    configmap_update(
                      users_dir,
                      "2026_10_13_02",
                      [
                        ("tls.crt", @testcerts.users_renewed_chain + "\n"),
                        ("tls.key", @testcerts.users_renewed_key + "\n"),
                      ],
                      replaces="2026_10_13_01",
                    )
                  },
                ),
                (
                  "rewriting the default pair",
                  () => {
                    write(default_dir, "tls.crt", @testcerts.ecdsa_chain + "\n")
                    write(default_dir, "tls.key", @testcerts.ecdsa_key + "\n")
                  },
                ),
              ]
              let out = [smock.presented_by_sni(certs, snis)]
              for i, step in steps {
                let (name, change) = step
                change()
                let entry = smock
                  .certificate_entries(i + 1)
                  .split("\n")
                  .last()
                  .unwrap()
                out.push(
                  (
                    $|\{name}:
                    $|\{entry}
                    $|\{smock.presented_by_sni(certs, snis)}
                    $|\{smock.metric(expiry_metric)}
                  ),
                )
              }
              inspect(
                out.join("\n"),
                content=(
                  #|SNI users.example.com: smock-test-users
                  #|no SNI: smock-test-rsa
                  #|a Secret-style update of the Mock's pair:
                  #|{"level":"info","msg":"TLS certificate reloaded","mock":"users","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2124-07-01T00:00:00.000Z"}
                  #|SNI users.example.com: smock-test-users-renewed
                  #|no SNI: smock-test-rsa
                  #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4922899200
                  #|smock_tls_certificate_expiry_timestamp_seconds{mock="users"} 4875465600
                  #|rewriting the default pair:
                  #|{"level":"info","msg":"TLS certificate reloaded","mock":"","certFile":"*/tls.crt","keyFile":"*/tls.key","expiry":"2125-01-01T00:00:00.000Z"}
                  #|SNI users.example.com: smock-test-users-renewed
                  #|no SNI: smock-test-ecdsa
                  #|smock_tls_certificate_expiry_timestamp_seconds{mock=""} 4891363200
                  #|smock_tls_certificate_expiry_timestamp_seconds{mock="users"} 4875465600
                ),
              )
            },
          )
        })
      })
    })
  })
}

///|
async test "smock serve refuses to start when a Mock's certificate pair cannot be loaded, as for the default pair, or when the per-Mock setting is not a mapping of Mock names to file pairs" {
  with_certificates(certs => {
    let missing = "\{certs.dir}/missing.pem"
    let users_pair = (cert : String, key : String) => {
      let entry : Json = {
        "users": {
          "certFile": Json::string(cert),
          "keyFile": Json::string(key),
        },
      }
      entry.stringify()
    }
    let runs : Array[(Array[String], Map[String, String])] = [
      (
        [..certs.args(), "--tls-mock-certs", users_pair(missing, certs.rsa_key)],
        Map([]),
      ),
      (
        [
          ..certs.args(),
          "--tls-mock-certs",
          users_pair(certs.rsa_chain, certs.other_key),
        ],
        Map([]),
      ),
      (certs.args(), { "SMOCK_TLS_MOCK_CERTS": "not JSON" }),
      ([..certs.args(), "--tls-mock-certs", "[]"], Map([])),
      (
        [
          ..certs.args(),
          "--tls-mock-certs",
          "{\"users\":{\"certFile\":\"x.pem\"}}",
        ],
        Map([]),
      ),
      (
        [
          ..certs.args(),
          "--tls-mock-certs",
          "{\"\":{\"certFile\":\"x.pem\",\"keyFile\":\"y.pem\"}}",
        ],
        Map([]),
      ),
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
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"users","certFile":"*/missing.pem","keyFile":"*/rsa-key.pem","error":"cannot read the certificate file: no such file"}
        #|---
        #|status 1
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"error","msg":"cannot load the TLS certificate","mock":"users","certFile":"*/rsa-chain.pem","keyFile":"*/other-key.pem","error":"the private key does not match the leaf certificate"}
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "not JSON" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): must be a JSON object that maps each Mock name to {"certFile": <path>, "keyFile": <path>}
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "[]" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): must be a JSON object that maps each Mock name to {"certFile": <path>, "keyFile": <path>}
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "{\"users\":{\"certFile\":\"x.pem\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): the entry of the Mock "users" must be {"certFile": <path>, "keyFile": <path>}, with paths that are not empty
        #|---
        #|status 2
        #|not JSON: smock serve: invalid value "{\"\":{\"certFile\":\"x.pem\",\"keyFile\":\"y.pem\"}}" for --tls-mock-certs (SMOCK_TLS_MOCK_CERTS): a Mock name must not be empty
      ),
    )
  })
}

///|
/// A Definition file that declares the Mocks in `mocks`, each with its
/// Hosts.
fn mocks_file(mocks : Array[(String, Array[String])]) -> String {
  let declared = mocks.map(mock => {
    let hosts = mock.1.map(host => Json::string(host))
    ({ "name": Json::string(mock.0), "hosts": Json::array(hosts) } : Json)
  })
  ({ "mocks": Json::array(declared) } : Json).stringify()
}

///|
async test "SNI follows the Hosts of the current definition set, and a Mock with a certificate that the set does not declare gets none until a reload declares it, with a warning each time it goes missing" {
  let users_only = mocks_file([("users", ["users.example.com"])])
  with_definitions([("mocks.json", users_only)], dir => {
    with_certificates(certs => {
      with_pair(@testcerts.users_chain, @testcerts.users_key, users_dir => {
        with_pair(@testcerts.orders_chain, @testcerts.orders_key, orders_dir => {
          let mapping = mock_certs([
            ("users", users_dir),
            ("orders", orders_dir),
          ])
          let stopped = with_smock(
            [
              "--dir",
              dir,
              "--port",
              "0",
              "--tls-mock-certs",
              mapping,
              ..certs.args(),
            ],
            smock => {
              let snis = [
                Some("users.example.com"),
                Some("people.example.com"),
                Some("orders.example.com"),
              ]
              let out = [smock.presented_by_sni(certs, snis)]
              let mut status = smock.status()
              let reloads = [
                mocks_file([
                  ("users", ["people.example.com"]),
                  ("orders", ["orders.example.com"]),
                ]),
                users_only,
              ]
              for mocks in reloads {
                write(dir, "mocks.json", mocks)
                status = smock.reloaded(status)
                out.push(
                  "after a reload: \{last_reload(status)}\n\{smock.presented_by_sni(certs, snis)}",
                )
              }
              inspect(
                out.join("\n"),
                content=(
                  #|SNI users.example.com: smock-test-users
                  #|SNI people.example.com: smock-test-rsa
                  #|SNI orders.example.com: smock-test-rsa
                  #|after a reload: "swapped"
                  #|SNI users.example.com: smock-test-rsa
                  #|SNI people.example.com: smock-test-users
                  #|SNI orders.example.com: smock-test-orders
                  #|after a reload: "swapped"
                  #|SNI users.example.com: smock-test-users
                  #|SNI people.example.com: smock-test-rsa
                  #|SNI orders.example.com: smock-test-rsa
                ),
              )
            },
          )
          inspect(
            log_entries(stopped.logs.filter(is_certificate_entry)),
            content=(
              #|{"level":"warn","msg":"TLS certificate for a Mock that is not declared","mock":"orders","certFile":"*/tls.crt","keyFile":"*/tls.key"}
              #|{"level":"warn","msg":"TLS certificate for a Mock that is not declared","mock":"orders","certFile":"*/tls.crt","keyFile":"*/tls.key"}
            ),
          )
        })
      })
    })
  })
}
