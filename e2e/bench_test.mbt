// Seam 2 tests of the release benchmark's request mix (bench/requests.json)
// and definition set (bench/definitions/), and of the set's Scenario
// variant (bench/definitions-scenarios/). bench/bench.py sends these
// requests to smock under load; here each one is sent once, over the plain
// and the TLS port, so that a request that no longer reaches the Stub the
// mix names for it fails a test instead of quietly measuring something
// else.

///|
/// The benchmark's definitions directory, relative to the module root.
let bench_definitions : String = "bench/definitions"

///|
/// The directory of the Scenario variant of the benchmark's definitions,
/// relative to the module root.
let bench_scenario_definitions : String = "bench/definitions-scenarios"

///|
/// One request of the mix and what smock should do with it, as
/// bench/requests.json gives them.
priv struct MixRequest {
  name : String
  meth : String
  host : String
  target : String
  headers : Array[(String, String)]
  body : String?
  session : String
  status : Int
  mock : String
  stub : String
  via_default : Bool
}

///|
/// Reads the request mix.
async fn read_mix() -> Array[MixRequest] {
  guard @fs.read_file("bench/requests.json").json()
    is Object({ "requests": Array(requests), .. }) else {
    fail("bench/requests.json has no requests array")
  }
  requests.map(request => {
    guard request
      is Object(
        {
          "name": String(name),
          "method": String(meth),
          "host": String(host),
          "target": String(target),
          "headers": Array(headers),
          "body": body,
          "expect": Object(
            {
              "session": String(session),
              "status": Number(status, ..),
              "mock": String(mock),
              "stub": String(stub),
              "viaDefault": via_default,
              ..
            }
          ),
          ..
        }
      ) else {
      fail("a request of the mix lacks a field: \{request.stringify()}")
    }
    let headers = headers.map(header => {
      guard header is Array([String(name), String(value)]) else {
        fail("\{name}: a header is not a [name, value] pair")
      }
      (name, value)
    })
    let body = match body {
      String(body) => Some(body)
      Null => None
      _ => fail("\{name}: the body is neither a string nor null")
    }
    {
      name,
      meth,
      host,
      target,
      headers,
      body,
      session,
      status: status.to_int(),
      mock,
      stub,
      via_default: via_default is True,
    }
  })
}

///|
/// The request as raw bytes: the request line, `Host`, the mix's headers
/// and, with a body, its `Content-Length` and the body.
fn MixRequest::raw(self : MixRequest) -> String {
  raw_request(
    self.meth,
    self.target,
    host=self.host,
    headers=self.headers,
    body?=self.body,
  )
}

///|
async test "bench/each request of the mix gets its status from the Stub and the Mock the mix names, over both ports, and is in the Journal under the Session in its baggage" {
  let mix = read_mix()
  with_certificates(certs => {
    let _ = with_smock(
      ["--dir", bench_definitions, "--port", "0", ..certs.args()],
      smock => {
        let problems = []
        for over in [Plain, Tls(certs)] {
          for request in mix {
            let conn = smock.connect(over~)
            defer conn.close()
            conn.write(request.raw())
            let response = read_response(conn)
            let expected = "HTTP/1.1 \{request.status} "
            if !response.has_prefix(expected) {
              problems.push(
                "\{request.name}: expected \{expected}, got \{response}",
              )
            }
          }
        }
        for request in mix {
          let (status, page) = smock.journal(session=request.session)
          guard status == 200 &&
            page is Object({ "entries": Array(entries), .. }) else {
            problems.push(
              "\{request.name}: the Journal query failed: \{status}",
            )
            continue
          }
          let expected : Json = {
            "mock": request.mock,
            "stub": request.stub,
            "status": request.status,
            "viaDefault": request.via_default,
          }
          let found = entries.map(entry => {
            guard entry
              is Object(
                {
                  "mock": mock,
                  "stub": stub,
                  "status": status,
                  "viaDefault": via_default,
                  ..
                }
              ) else {
              return Json::string("an entry without mock, stub or status")
            }
            Json::object({
              "mock": mock,
              "stub": stub,
              "status": status,
              "viaDefault": via_default,
            })
          })
          if found != [expected, expected] {
            problems.push(
              "\{request.name}: expected two entries like \{expected.stringify()}, got \{Json::array(found).stringify()}",
            )
          }
        }
        debug_inspect(problems, content="[]")
      },
    )
  })
}

///|
/// The Stubs of the benchmark's definition set by ID, and the Mocks it
/// declares, read from its JSON Definition files.
async fn read_bench_definitions() -> (Map[String, Json], Array[String]) {
  let stubs : Map[String, Json] = Map([])
  let mocks = []
  for name in @fs.readdir(bench_definitions) {
    guard name.has_suffix(".json") else { continue }
    guard @fs.read_file("\{bench_definitions}/\{name}").json() is Object(file) else {
      fail("\{name} is not a JSON object")
    }
    if file.get("mocks") is Some(Array(declared)) {
      for mock in declared {
        guard mock is Object({ "name": String(mock), .. }) else { continue }
        mocks.push(mock)
      }
    }
    if file.get("stubs") is Some(Array(declared)) {
      for stub in declared {
        guard stub is Object({ "id": String(id), .. }) else { continue }
        stubs[id] = stub
      }
    }
  }
  (stubs, mocks)
}

///|
/// The kinds of conditions a Stub has, such as `path:exact`,
/// `header:pattern` or `body:json`.
fn condition_kinds(stub : Json) -> Array[String] {
  guard stub is Object({ "request": Object(request), .. }) else { return [] }
  fn kind(value : Json) -> String {
    match value {
      String(_) => "exact"
      Object({ "pattern": _, .. }) => "pattern"
      Object({ "json": _, .. }) => "json"
      _ => "other"
    }
  }

  let kinds = []
  if request.get("path") is Some(path) {
    kinds.push("path:\{kind(path)}")
  }
  for field in ["query", "headers"] {
    if request.get(field) is Some(Object(conditions)) {
      for _, condition in conditions {
        kinds.push("\{field}:\{kind(condition)}")
      }
    }
  }
  if request.get("body") is Some(body) {
    kinds.push("body:\{kind(body)}")
  }
  kinds
}

///|
async test "bench/the mix reaches several Mocks by Host and the Default Mock, and many Stubs with exact, pattern and json conditions, with realistic headers and bodies" {
  let mix = read_mix()
  let (stubs, mocks) = read_bench_definitions()
  let reached = []
  let via_default = []
  let kinds = []
  let with_body = []
  let missing = []
  let common = [
    "user-agent", "accept", "accept-encoding", "authorization", "traceparent", "baggage",
    "x-request-id",
  ]
  for request in mix {
    if !reached.contains(request.mock) {
      reached.push(request.mock)
    }
    if request.via_default {
      via_default.push(request.name)
    }
    match stubs.get(request.stub) {
      Some(stub) =>
        for kind in condition_kinds(stub) {
          if !kinds.contains(kind) {
            kinds.push(kind)
          }
        }
      None => missing.push("\{request.name}: no Stub \{request.stub}")
    }
    if request.body is Some(_) {
      with_body.push(request.name)
    }
    let names = request.headers.map(header => header.0.to_lower())
    for name in common {
      if !names.contains(name) {
        missing.push("\{request.name}: no \{name} header")
      }
    }
  }
  reached.sort_by((a, b) => a.lexical_compare(b))
  kinds.sort_by((a, b) => a.lexical_compare(b))
  let summary : Json = {
    "mocks": ToJson::to_json(mocks),
    "mocksReached": ToJson::to_json(reached),
    "viaDefault": ToJson::to_json(via_default),
    "stubs": ToJson::to_json(stubs.length()),
    "conditionsMatched": ToJson::to_json(kinds),
    "withBody": ToJson::to_json(with_body),
    "missing": ToJson::to_json(missing),
  }
  json_inspect(summary, content={
    "mocks": ["catalog", "users", "orders", "payments"],
    "mocksReached": ["catalog", "orders", "payments", "users"],
    "viaDefault": ["legacy-payment"],
    "stubs": 1161,
    "conditionsMatched": [
      "body:json", "body:pattern", "headers:exact", "headers:pattern", "path:exact",
      "path:pattern", "query:exact", "query:pattern",
    ],
    "withBody": ["create-order", "update-order-status", "create-payment"],
    "missing": [],
  })
}

///|
async test "bench/in the Scenario variant, each request of the mix gets its status from the Stub the mix names and its twin in turn, over both ports, and moves its Scenario every time" {
  let mix = read_mix()
  with_certificates(certs => {
    let _ = with_smock(
      ["--dir", bench_scenario_definitions, "--port", "0", ..certs.args()],
      smock => {
        let problems = []
        for over in [Plain, Tls(certs), Plain] {
          for request in mix {
            let conn = smock.connect(over~)
            defer conn.close()
            conn.write(request.raw())
            let response = read_response(conn)
            let expected = "HTTP/1.1 \{request.status} "
            if !response.has_prefix(expected) {
              problems.push(
                "\{request.name}: expected \{expected}, got \{response}",
              )
            }
          }
        }
        debug_inspect(problems, content="[]")
        // Each request's Session: the Stubs that answered it, oldest
        // first, and how each moved its Scenario.
        let moves : Map[String, Json] = Map([])
        for request in mix {
          guard smock.journal(session=request.session)
            is (200, Object({ "entries": Array(entries), .. })) else {
            fail("\{request.name}: the Journal query failed")
          }
          moves[request.name] = Json::array(
            entries.map(entry => {
              guard entry
                is Object(
                  {
                    "mock": String(mock),
                    "stub": String(stub),
                    "scenario": Object(
                      {
                        "name": String(name),
                        "from": String(from),
                        "to": String(to),
                        ..
                      }
                    ),
                    ..
                  }
                ) else {
                return Json::string("no move: \{entry.stringify()}")
              }
              Json::string("\{mock}/\{stub}: \{name} \{from} -> \{to}")
            }),
          )
        }
        json_inspect(moves, content={
          "catalog-item": [
            "catalog/catalog-item-00317: catalog-item Started -> Seen", "catalog/catalog-item-00317-seen: catalog-item Seen -> Started",
            "catalog/catalog-item-00317: catalog-item Started -> Seen",
          ],
          "catalog-search": [
            "catalog/catalog-search: catalog-search Started -> Seen", "catalog/catalog-search-seen: catalog-search Seen -> Started",
            "catalog/catalog-search: catalog-search Started -> Seen",
          ],
          "user-profile": [
            "users/user-10042: user-profile Started -> Seen", "users/user-10042-seen: user-profile Seen -> Started",
            "users/user-10042: user-profile Started -> Seen",
          ],
          "user-preferences": [
            "users/user-preferences: user-preferences Started -> Seen", "users/user-preferences-seen: user-preferences Seen -> Started",
            "users/user-preferences: user-preferences Started -> Seen",
          ],
          "create-order": [
            "orders/create-order-partner-gold: create-order Started -> Seen", "orders/create-order-partner-gold-seen: create-order Seen -> Started",
            "orders/create-order-partner-gold: create-order Started -> Seen",
          ],
          "get-order": [
            "orders/get-order: get-order Started -> Seen", "orders/get-order-seen: get-order Seen -> Started",
            "orders/get-order: get-order Started -> Seen",
          ],
          "update-order-status": [
            "orders/update-order-status: update-order-status Started -> Seen", "orders/update-order-status-seen: update-order-status Seen -> Started",
            "orders/update-order-status: update-order-status Started -> Seen",
          ],
          "create-payment": [
            "payments/create-payment-eur: create-payment Started -> Seen", "payments/create-payment-eur-seen: create-payment Seen -> Started",
            "payments/create-payment-eur: create-payment Started -> Seen",
          ],
          "legacy-payment": [
            "payments/payment-000042: legacy-payment Started -> Seen", "payments/payment-000042-seen: legacy-payment Seen -> Started",
            "payments/payment-000042: legacy-payment Started -> Seen",
          ],
        })
      },
    )
  })
}

///|
async test "bench/smock check finds nothing to warn about in the Scenario variant" {
  inspect(check([bench_scenario_definitions]), content="status 0\n")
}
