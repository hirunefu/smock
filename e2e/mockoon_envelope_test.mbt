// Seam 2 tests of smock's own lines in the mockoon log format: every line
// smock writes goes to stdout, in Mockoon's envelope (`app`, `level`,
// `message` and `timestamp`, with the line's own fields beside them and the
// keys sorted at every depth), and stderr stays empty. Lines are compared
// whole, byte for byte, with the value of `timestamp` masked once its form
// is checked, and ports and paths the test did not choose replaced.

///|
/// The lines among `lines` whose `message` is one of `messages`, in their
/// order.
fn with_messages(
  lines : Array[String],
  messages : Array[String],
) -> Array[String] {
  lines.filter(line => {
    let entry = @json.parse(line) catch { _ => return false }
    entry is Object({ "message": String(message), .. }) &&
    messages.contains(message)
  })
}

///|
/// `line` with its timestamp masked (`mask_timestamp`), and each text of
/// `replace` written as the placeholder it comes with.
fn masked_line(
  line : String,
  replace~ : Array[(String, String)] = [],
) -> String {
  let mut line = mask_timestamp(line)
  for pair in replace {
    let (text, placeholder) = pair
    line = line.replace_all(old=text, new=placeholder)
  }
  line
}

///|
async test "with SMOCK_LOG_FORMAT=mockoon, smock's own lines go to stdout in Mockoon's envelope, keeping their messages and fields, and stderr stays empty" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", "--seed", "42", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let out = []
      let stopped = with_smock(args, env~, smock => {
        // Read while smock runs: a line held in a buffer would not come.
        let replace = [
          ("0.0.0.0:\{smock.admin_port}\"", "0.0.0.0:<admin port>\""),
          ("0.0.0.0:\{smock.port}\"", "0.0.0.0:<plain port>\""),
          ("0.0.0.0:\{smock.tls_port}\"", "0.0.0.0:<TLS port>\""),
          (certs.dir, "<certs>"),
        ]
        for line in with_messages(smock.stdout, ["random seed", "listening"]) {
          out.push(masked_line(line, replace~))
        }
      })
      out.push("stderr: \{stopped.logs.length()} lines")
      inspect(
        out.join("\n"),
        content=(
          #|{"app":"smock","level":"info","message":"random seed","seed":42,"timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<admin port>","app":"smock","level":"info","listener":"admin","message":"listening","timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<plain port>","app":"smock","level":"info","listener":"plain","message":"listening","timestamp":"<timestamp>"}
          #|{"address":"0.0.0.0:<TLS port>","app":"smock","certFile":"<certs>/rsa-chain.pem","keyFile":"<certs>/rsa-key.pem","level":"info","listener":"tls","message":"listening","timestamp":"<timestamp>"}
          #|stderr: 0 lines
        ),
      )
    })
  })
}
