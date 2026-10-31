// Seam 2 golden comparison of the mockoon log format with the Mockoon CLI:
// smock's Mockoon-equivalent lines must equal lines that Mockoon wrote,
// adapted only by fixed rules, one per difference that spec #250 decided.
// A difference that no rule explains fails the test, so a new difference is
// decided first, then written here as a rule. The golden lines are in
// e2e/golden/mockoon/, whose README.md says where they come from and why
// they hold for Mockoon v9.10.0.

///|
/// The lines the Mockoon CLI wrote for the environment `probe`: its started
/// line, its token line, the `Transaction recorded` line of `GET /t/add`,
/// then the error line and the `Transaction recorded` line of
/// `GET /t/upper-number`, whose template failed.
let mockoon_golden : String = "e2e/golden/mockoon/probe.log"

///|
/// The Mock `probe`, as smock writes the trial's environment: the Stub
/// `t-add` at `/t/add`, whose template adds two numbers, and the Stub
/// `t-upper-number` at `/t/upper-number`, whose template fails. Mockoon's
/// `uppercase` failed on a number; smock's writes a number as text, so the
/// Stub gives it an array, on which it fails.
let probe_mock : String =
  #|mocks:
  #|  - { name: probe }
  #|stubs:
  #|  - id: t-add
  #|    mock: probe
  #|    request: { method: GET, path: /t/add }
  #|    response: { status: 200, template: true, body: "${add(1, 2)}" }
  #|  - id: t-upper-number
  #|    mock: probe
  #|    request: { method: GET, path: /t/upper-number }
  #|    response: { status: 200, template: true, body: "${uppercase(range(1, 2))}" }

///|
/// The Mockoon-equivalent lines among `lines`, in order: those whose
/// `message` is `Server started on port …`, `Server stopped`,
/// `Transaction recorded` or `Error while serving the content: …`.
fn mockoon_equivalent(lines : Array[String]) -> Array[String] {
  lines.filter(line => {
    let message = message_of(line)
    message.has_prefix("Server started on port ") ||
    message == "Server stopped" ||
    message == "Transaction recorded" ||
    message.has_prefix("Error while serving the content: ")
  })
}

///|
/// The start and the end of the string value of `key` in the log line
/// `line`, without its quotes, or `None` when `line` has no such value.
/// An escaped quote inside the value does not end it.
fn string_value_at(line : String, key : String) -> (Int32, Int32)? {
  let opening = "\"\{key}\":\""
  guard line.find(opening) is Some(i) else { return None }
  let start = i + opening.length()
  let mut j = start
  while j < line.length() {
    if line[j] == '\\' {
      j += 2
    } else if line[j] == '"' {
      return Some((start, j))
    } else {
      j += 1
    }
  }
  None
}

///|
/// `line` with the code units from `start` to `end` replaced by `text`.
fn spliced(line : String, start : Int32, end : Int32, text : String) -> String {
  "\{line[:start]}\{text}\{line[end:]}"
}

///|
/// `text` as the inside of a JSON string, escaped as JSON.stringify
/// escapes it, without its quotes.
fn json_string_inside(text : String) -> String {
  let quoted = Json::string(text).stringify()
  quoted[1:quoted.length() - 1].to_owned()
}

///|
/// A rule that adapts the golden lines for one decided difference: what it
/// does, and the lines it makes of them.
struct GoldenRule {
  name : String
  adapt : (Array[String]) -> Array[String]
}

///|
/// The rules, in the order they apply, one per difference that spec #250
/// decided between Mockoon's lines and smock's. `port` is smock's plain
/// port, `stub_ids` the ID of each Stub by its path as written, and
/// `messages` the `message` of each 500 `template failed` body, in the
/// order of the requests.
fn golden_rules(
  port~ : Int32,
  stub_ids~ : Map[String, String],
  messages~ : Array[String],
) -> Array[GoldenRule] {
  let fixed_text = "Error while serving the content: "
  [
    {
      name: "app becomes \"smock\"",
      adapt: lines => {
        lines.map(line => {
          guard string_value_at(line, "app") is Some((start, end)) else {
            return line
          }
          spliced(line, start, end, "smock")
        })
      },
    },
    {
      name: "environmentUUID goes",
      adapt: lines => {
        lines.map(line => {
          guard string_value_at(line, "environmentUUID") is Some((start, end)) else {
            return line
          }
          let key = ",\"environmentUUID\":\""
          spliced(line, start - key.length(), end + 1, "")
        })
      },
    },
    {
      name: "the token line goes",
      adapt: lines => {
        lines.filter(line => {
          !message_of(line).has_prefix("Admin API token (auto-generated): ")
        })
      },
    },
    {
      name: "the port becomes smock's plain port",
      adapt: lines => {
        lines.map(line => {
          let started = "Server started on port "
          guard string_value_at(line, "message") is Some((start, end)) &&
            line[start:end].has_prefix(started) else {
            return line
          }
          spliced(line, start + started.length(), end, port.to_string())
        })
      },
    },
    {
      name: "routePath gains its leading /",
      adapt: lines => {
        lines.map(line => {
          guard string_value_at(line, "routePath") is Some((start, _)) else {
            return line
          }
          spliced(line, start, start, "/")
        })
      },
    },
    {
      name: "routeUUID becomes the Stub ID",
      adapt: lines => {
        lines.map(line => {
          guard string_value_at(line, "routePath") is Some((start, end)) &&
            stub_ids.get(line[start:end].to_owned()) is Some(id) &&
            string_value_at(line, "routeUUID") is Some((start, end)) else {
            return line
          }
          spliced(line, start, end, id)
        })
      },
    },
    {
      name: "smock's message follows the fixed text",
      adapt: lines => {
        let mut k = 0
        lines.map(line => {
          guard string_value_at(line, "message") is Some((start, end)) &&
            line[start:end].has_prefix(fixed_text) &&
            k < messages.length() else {
            return line
          }
          let message = json_string_inside(messages[k])
          k += 1
          spliced(line, start + fixed_text.length(), end, message)
        })
      },
    },
    {
      name: "the status after a template failure becomes 500",
      adapt: lines => {
        lines.mapi((i, line) => {
          guard i > 0 &&
            message_of(lines[i - 1]).has_prefix(fixed_text) &&
            message_of(line) == "Transaction recorded" else {
            return line
          }
          let key = ",\"responseStatus\":"
          guard line.find(key) is Some(at) &&
            line[at + key.length():].find(",") is Some(length) else {
            return line
          }
          let start = at + key.length()
          spliced(line, start, start + length, "500")
        })
      },
    },
    {
      name: "timestamp is masked",
      adapt: lines => lines.map(line => masked_line(line)),
    },
  ]
}

///|
/// How many lines `rule` changed when it made `after` of `before`: the
/// lines it dropped, or those whose text it changed.
fn changed_lines(before : Array[String], after : Array[String]) -> Int32 {
  if before.length() != after.length() {
    return before.length() - after.length()
  }
  let mut changed = 0
  for i, line in before {
    if line != after[i] {
      changed += 1
    }
  }
  changed
}

///|
/// The `message` of the JSON body of `response`, as `read_response`
/// renders it, or `response` itself when it has none.
fn body_message(response : String) -> String {
  let body = match response.find("\n\n") {
    Some(i) => response[i + 2:].to_owned()
    None => return response
  }
  let parsed = @json.parse(body) catch { _ => return response }
  match parsed {
    Object({ "message": String(message), .. }) => message
    _ => response
  }
}

///|
async test "smock's Mockoon-equivalent lines for the Mock probe equal the lines Mockoon v9.10.0 wrote, adapted by one rule per decided difference" {
  with_definitions([("probe.yaml", probe_mock)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let responses = [
        smock.send("GET", "/t/add"),
        smock.send("GET", "/t/upper-number"),
      ]
      // Read while smock runs: the trial's file has no Server stopped line.
      smock.transaction_lines(2) |> ignore
      let served = mockoon_equivalent(smock.stdout).map(line => {
        masked_line(line)
      })
      let rules = golden_rules(
        port=smock.port,
        stub_ids={ "/t/add": "t-add", "/t/upper-number": "t-upper-number" },
        messages=[body_message(responses[1])],
      )
      let mut adapted = @fs.read_file(mockoon_golden)
        .text()
        .split("\n")
        .filter(line => line != "")
        .map(line => line.to_owned())
        .collect()
      let applied = []
      for rule in rules {
        let next = (rule.adapt)(adapted)
        applied.push("\{rule.name}: \{changed_lines(adapted, next)} lines")
        adapted = next
      }
      if adapted != served {
        fail(
          (
            $|smock's Mockoon-equivalent lines differ from the golden lines, adapted:
            $|\{adapted.join("\n")}
            $|smock:
            $|\{served.join("\n")}
            $|Decide the difference, then write it as a rule.
          ),
        )
      }
      let placeholders = port_placeholders(smock)
      inspect(
        (
          $|\{responses.join("\n")}
          $|\{applied.join("\n")}
          $|\{served.map(line => masked_line(line, replace=placeholders)).join("\n")}
        ),
        content=(
          #|HTTP/1.1 200 OK
          #|Smock-Mock: probe; via=default
          #|Date: <now>
          #|Content-Length: 1
          #|
          #|3
          #|HTTP/1.1 500 Internal Server Error
          #|Content-Type: application/json
          #|Smock-Mock: probe; via=default
          #|Date: <now>
          #|Content-Length: 163
          #|
          #|{"error":"template failed","stub":"t-upper-number","at":"/response/body","message":"uppercase(): argument 1 must be a string, a number or a boolean, not an array"}
          #|app becomes "smock": 5 lines
          #|environmentUUID goes: 5 lines
          #|the token line goes: 1 lines
          #|the port becomes smock's plain port: 1 lines
          #|routePath gains its leading /: 1 lines
          #|routeUUID becomes the Stub ID: 1 lines
          #|smock's message follows the fixed text: 1 lines
          #|the status after a template failure becomes 500: 1 lines
          #|timestamp is masked: 4 lines
          #|{"app":"smock","environmentName":"probe","level":"info","message":"Server started on port <plain port>","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"probe","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/t/add","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"probe","level":"error","message":"Error while serving the content: uppercase(): argument 1 must be a string, a number or a boolean, not an array","routePath":"/t/upper-number","routeUUID":"t-upper-number","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"probe","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/t/upper-number","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
        ),
      )
    })
  })
}
