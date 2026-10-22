// Reading templates that read environment variables: a load takes the
// variables `--template-env` lists, with their values, beside the files,
// and a template that reads any other name, or `env` without exactly one
// name, does not load.

///|
/// `REGION` set and `ZONE` listed but unset.
let listed : @template.Env = @template.Env([
  ("REGION", Some("eu-west-1")),
  ("ZONE", None),
])

///|
/// Loads the Definition file `a.json`, holding Mock `m` and `stubs`, with
/// the variables `listed`, and renders every diagnostic, one per line, or
/// `valid`.
fn env_problems(stubs : Array[String]) -> String {
  let file = "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [\{stubs.join(", ")}] }"
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  match @definitions.load(set, env=listed) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
/// A Stub of Mock `m` with the templated `response`, given as JSON members
/// beside `"template": true`.
fn templated(id : String, response : String) -> String {
  "{ \"id\": \"\{id}\", \"mock\": \"m\", \"response\": { \"template\": true, \{response} } }"
}

///|
test "a template reads listed variables, set or unset, in every templated field" {
  inspect(
    env_problems([
      templated(
        "a",
        (
          #|"status": 200, "headers": { "X-Region": "${env.REGION}" },
          #|"json": { "region": "${env.REGION ?? 'local'}", "zone": "${env.ZONE ?? null}" }
        ),
      ),
      templated("b", "\"status\": 200, \"body\": \"${env['ZONE'] ?? 'none'}\""),
    ]),
    content="valid",
  )
}

///|
test "a name that is not listed, env without exactly one name, and a loop variable named env are load errors at the field's JSON Pointer" {
  inspect(
    env_problems([
      templated(
        "unlisted",
        (
          #|"status": 200, "headers": { "X-Home": "${env.HOME}" },
          #|"json": { "secret": "${env.SMOCK_ADMIN_TOKEN ?? ''}" }
        ),
      ),
      templated("alone", "\"status\": 200, \"body\": \"${env}\""),
      templated("deep", "\"status\": 200, \"body\": \"${env.REGION.x}\""),
      templated(
        "loop",
        (
          #|"status": 200,
          #|"json": { "$each": "range(1, 2)", "as": "env", "do": "${loop.index}" }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/response/headers/X-Home: template: column 3: env.HOME: the environment variable "HOME" is not listed in --template-env
      #|a.json: /stubs/0/response/json/secret: template: column 3: env.SMOCK_ADMIN_TOKEN: the environment variable "SMOCK_ADMIN_TOKEN" is not listed in --template-env
      #|a.json: /stubs/1/response/body: template: column 3: env: env takes exactly one name, such as env.REGION
      #|a.json: /stubs/2/response/body: template: column 3: env.REGION.x: env takes exactly one name, such as env.REGION
      #|a.json: /stubs/3/response/json/as: template: "env" cannot be a loop variable: it is a request field, env, vars, data, loop or a reserved word
    ),
  )
}

///|
test "without listed variables, a template that reads env does not load" {
  let file =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [{ "id": "a", "mock": "m",
    #|    "response": { "status": 200, "template": true, "body": "${env.REGION ?? 'local'}" } }] }
  let set : @definitions.DefinitionSet = {
    files: [("a.json", @utf8.encode(file))],
    body_files: [],
  }
  inspect(
    match @definitions.load(set) {
      Ok(_) => "valid"
      Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
    },
    content=(
      #|a.json: /stubs/0/response/body: template: column 3: env.REGION: the environment variable "REGION" is not listed in --template-env
    ),
  )
}

///|
test "an Ephemeral Stub reads the listed variables it is given, and gets the same load errors" {
  let read = (stub : String) => {
    match
      @definitions.ephemeral_stub(
        @json.parse(stub) catch {
          _ => panic()
        },
        id="eph-1",
        mock="m",
        env=listed,
      ) {
      Ok(_) => "valid"
      Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
    }
  }
  inspect(
    [
      read(
        "{ \"response\": { \"status\": 200, \"template\": true, \"body\": \"${env.REGION}\" } }",
      ),
      read(
        "{ \"response\": { \"status\": 200, \"template\": true, \"body\": \"${env.HOME}\" } }",
      ),
    ].join("\n"),
    content=(
      #|valid
      #|/response/body: template: column 3: env.HOME: the environment variable "HOME" is not listed in --template-env
    ),
  )
}
