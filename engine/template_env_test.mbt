// Seam 1 tests of the `env` root: the environment variables that
// `--template-env` lists, with the values read once at startup and given
// to the engine with its snapshot, for every load after it.

///|
/// A Stub that writes the variable `REGION`, with `local` when it is unset.
let region_stub : (String, String) = (
  "region.yaml",
  (
    #|mocks:
    #|  - name: geo
    #|stubs:
    #|  - id: region
    #|    mock: geo
    #|    request: { method: GET, path: /region }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        region: ${env.REGION ?? 'local'}
  ),
)

///|
test "env.NAME gives a listed variable's value; a listed but unset one is missing, so ?? applies; an empty one is present" {
  let body = (value : String?) => {
    let h = harness([region_stub], env=@template.Env([("REGION", value)]))
    response(h.send("GET", "/region"))
  }
  inspect(
    [body(Some("eu-west-1")), body(None), body(Some(""))].join("\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: geo; via=default
      #|{"region":"eu-west-1"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: geo; via=default
      #|{"region":"local"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: geo; via=default
      #|{"region":""}
    ),
  )
}

///|
test "a value reaches a template error message that quotes it, and the Journal holds it only there" {
  let h = harness(
    [
      (
        "port.yaml",
        (
          #|mocks:
          #|  - name: geo
          #|stubs:
          #|  - id: port
          #|    mock: geo
          #|    request: { method: GET, path: /port }
          #|    response:
          #|      status: 200
          #|      template: true
          #|      json: { port: "${number(env.PORT)}" }
        ),
      ),
    ],
    env=@template.Env([("PORT", Some("eighty"))]),
  )
  inspect(
    describe(h.send("GET", "/port")),
    content=(
      #|plan:
      #|  status: 500
      #|  header: Content-Type: application/json
      #|  header: Smock-Mock: geo; via=default
      #|  body: "{\"error\":\"template failed\",\"stub\":\"port\",\"at\":\"/response/json/port\",\"message\":\"number(): \\\"eighty\\\" is not a JSON number\"}"
      #|  delay_ms: 0
      #|  fault: None
      #|journal:
      #|  session: None
      #|  host: None
      #|  mock: Some("geo")
      #|  via_default: true
      #|  request: GET /port HTTP/1.1
      #|  body: ""
      #|  stub: Some("port")
      #|  status: Some(500)
      #|  fault: None
      #|  template_error: at /response/json/port: "number(): \"eighty\" is not a JSON number"
      #|  received_at: 1791815405123
      #|near_miss: None
    ),
  )
}

///|
test "an Ephemeral Stub reads the variables the engine was given, and one that reads a name not listed is refused" {
  let h = harness(
    [region_stub],
    env=@template.Env([("REGION", Some("eu-west-1"))]),
  )
  let added = h.add(
    "geo",
    None,
    (
      #|{ "request": { "method": "GET", "path": "/eph" },
      #|  "response": { "status": 200, "template": true,
      #|    "body": "${env.REGION} ${env['REGION']}" } }
    ),
  )
  let unlisted = @json.parse(
    (
      #|{ "response": { "status": 200, "template": true, "body": "${env.HOME}" } }
    ),
  )
  let refused = h.engine.add_ephemeral_stub(mock="geo", session=None, unlisted).id catch {
      InvalidStub(problems) => problems.map(p => p.to_string()).join("\n")
      err => fail(@debug.to_string(err))
    }
  inspect(
    "\{added}\n\{response(h.send("GET", "/eph"))}\n\{refused}",
    content=(
      #|eph-1
      #|200
      #|Smock-Mock: geo; via=default
      #|eu-west-1 eu-west-1
      #|/response/body: template: column 3: env.HOME: the environment variable "HOME" is not listed in --template-env
    ),
  )
}

///|
test "a reload uses the values the engine was given at startup, and lists the same names" {
  let h = harness(
    [region_stub],
    env=@template.Env([("REGION", Some("eu-west-1"))]),
  )
  let reload = (files : Array[(String, String)]) => {
    reload_summary(h.reload(files))
  }
  let swapped = reload([
    (
      "region.yaml",
      (
        #|mocks:
        #|  - name: geo
        #|stubs:
        #|  - id: region
        #|    mock: geo
        #|    request: { method: GET, path: /region }
        #|    response:
        #|      status: 200
        #|      template: true
        #|      body: "reloaded in ${env.REGION}"
      ),
    ),
  ])
  let failed = reload([
    (
      "region.yaml",
      (
        #|mocks:
        #|  - name: geo
        #|stubs:
        #|  - id: region
        #|    mock: geo
        #|    response: { status: 200, template: true, body: "${env.ZONE}" }
      ),
    ),
  ])
  inspect(
    "\{swapped}\n\{response(h.send("GET", "/region"))}\n\{failed}",
    content=(
      #|Swapped at 1791815460000: 8f7955319664 -> a96a06e4227a
      #|200
      #|Smock-Mock: geo; via=default
      #|reloaded in eu-west-1
      #|Failed at 1791815460000: a96a06e4227a -> a96a06e4227a
      #|region.yaml: /stubs/0/response/body: template: column 3: env.ZONE: the environment variable "ZONE" is not listed in --template-env
    ),
  )
}

///|
test "the values are not part of the definition set digest" {
  let set : @definitions.DefinitionSet = {
    files: [(region_stub.0, @utf8.encode(region_stub.1))],
    body_files: [],
  }
  let digest = (value : String?) => {
    match @definitions.load(set, env=@template.Env([("REGION", value)])) {
      Ok(snapshot) => snapshot.digest
      Err(_) => "invalid"
    }
  }
  inspect(
    [
      digest(Some("eu-west-1")),
      digest(Some("us-east-1")),
      digest(None),
      set.digest(),
    ].join(" "),
    content=(
      #|8f7955319664 8f7955319664 8f7955319664 8f7955319664
    ),
  )
}
