// Seam 2 tests of `--template-env`: `smock serve`, `smock check` and
// `smock render` read the environment variables it lists, each from its own
// environment, and refuse names it may not list.

///|
/// A Stub that writes the variable `REGION`, with `local` when it is unset,
/// and a sample request for it.
let region_files : Array[(String, String)] = [
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
      #|      json:
      #|        region: ${env.REGION ?? 'local'}
    ),
  ),
  ("samples/region.json", "{ \"path\": \"/region\" }"),
]

///|
/// A value no log line or Admin API response holds by chance.
let region_value : String = "eu-west-1-q7z"

///|
/// The body of `GET /region`, the last line of the response.
async fn region_body(smock : Smock) -> String {
  let response = smock.get("/region")
  response[response.rev_find("\n").unwrap_or(-1) + 1:].to_owned()
}

///|
async test "smock serve reads the variables --template-env or SMOCK_TEMPLATE_ENV lists, once, and shows a value in no log line and not in the Admin status" {
  with_definitions(region_files, dir => {
    let out = []
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--template-env", "REGION"],
      env={ "REGION": region_value },
      smock => {
        out.push("flag: \{region_body(smock)}")
        let status = smock.admin("GET", "/v1/status")
        out.push(
          "the Admin status holds the value: \{status.body.contains(region_value)}",
        )
      },
    )
    out.push(
      "a log line holds the value: \{stopped.logs.iter().any(line => line.contains(region_value))}",
    )
    let _ = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_TEMPLATE_ENV": "REGION" },
      smock => out.push("variable, REGION unset: \{region_body(smock)}"),
    )
    inspect(
      out.join("\n"),
      content=(
        #|flag: {"region":"eu-west-1-q7z"}
        #|the Admin status holds the value: false
        #|a log line holds the value: false
        #|variable, REGION unset: {"region":"local"}
      ),
    )
  })
}

///|
async test "without --template-env, a template that reads env stops smock serve at startup, and smock check reports it" {
  with_definitions(region_files, dir => {
    let stopped = run_smock(["serve", "--dir", dir, "--port", "0"], env={
      "REGION": region_value,
    })
    inspect(
      "status \{stopped.status}\n" +
      log_entries(stopped.logs.filter(line => line.contains("\"error\""))),
      content=(
        #|status 1
        #|{"level":"error","msg":"invalid definitions","file":"region.yaml","pointer":"/stubs/0/response/json/region","error":"template: column 3: env.REGION: the environment variable \"REGION\" is not listed in --template-env"}
      ),
    )
    inspect(
      [
        check([dir]),
        check(["--template-env", "REGION", dir]),
        check([dir], env={ "SMOCK_TEMPLATE_ENV": "REGION" }),
      ].join("---\n"),
      content=(
        #|status 1
        #|region.yaml: /stubs/0/response/json/region: template: column 3: env.REGION: the environment variable "REGION" is not listed in --template-env
        #|---
        #|status 0
        #|---
        #|status 0
        #|
      ),
    )
  })
}

///|
async test "smock render reads the variables it lists from its own environment, by flag or SMOCK_TEMPLATE_ENV" {
  with_definitions(region_files, dir => {
    let body = (args : Array[String], env : Map[String, String]) => {
      let (status, stdout, stderr) = render_output(
        [
          "--dir",
          dir,
          "region",
          "--request",
          "\{dir}/samples/region.json",
          ..args,
        ],
        env~,
      )
      guard status == 0 else { return "status \{status}: \{stderr}" }
      match @json.parse(stdout) {
        { "response": { "body": { "data": String(data), .. }, .. }, .. } => data
        _ => "no body: \{stdout}"
      }
    }
    inspect(
      [
        body(["--template-env", "REGION"], { "REGION": region_value }),
        body([], { "SMOCK_TEMPLATE_ENV": "REGION", "REGION": "" }),
        body([], { "SMOCK_TEMPLATE_ENV": "REGION" }),
        body([], { "REGION": region_value }),
      ].join("\n"),
      content=(
        #|{"region":"eu-west-1-q7z"}
        #|{"region":""}
        #|{"region":"local"}
        #|status 1: region.yaml: /stubs/0/response/json/region: template: column 3: env.REGION: the environment variable "REGION" is not listed in --template-env
        #|
      ),
    )
  })
}

///|
async test "a name --template-env may not list is a usage error on serve, check and render" {
  with_definitions(region_files, dir => {
    let runs = [
      (["serve", "--template-env", "SMOCK_ADMIN_TOKEN"], Map([])),
      (["serve"], { "SMOCK_TEMPLATE_ENV": "REGION,1ZONE" }),
      (["check", "--template-env", "SMOCK_ADMIN_TOKEN", dir], Map([])),
      (["check", dir], { "SMOCK_TEMPLATE_ENV": "API-BASE" }),
      (
        [
          "render",
          "--dir",
          dir,
          "--request",
          "\{dir}/samples/region.json",
          "--template-env",
          "REGION,SMOCK_DIR",
          "region",
        ],
        Map([]),
      ),
    ]
    let out = []
    for run in runs {
      let (status, _, stderr) = smock_output(run.0, env=run.1)
      out.push("status \{status}: \{stderr.trim_end(chars="\n")}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|status 2: smock serve: invalid value "SMOCK_ADMIN_TOKEN" for --template-env (SMOCK_TEMPLATE_ENV): "SMOCK_ADMIN_TOKEN" starts with SMOCK_: smock's own variables cannot be listed
        #|status 2: smock serve: invalid value "REGION,1ZONE" for --template-env (SMOCK_TEMPLATE_ENV): "1ZONE" is not a variable name: letters, digits and _, starting with a letter or _
        #|status 2: smock check: invalid value "SMOCK_ADMIN_TOKEN" for --template-env (SMOCK_TEMPLATE_ENV): "SMOCK_ADMIN_TOKEN" starts with SMOCK_: smock's own variables cannot be listed
        #|status 2: smock check: invalid value "API-BASE" for --template-env (SMOCK_TEMPLATE_ENV): "API-BASE" is not a variable name: letters, digits and _, starting with a letter or _
        #|status 2: smock render: invalid value "REGION,SMOCK_DIR" for --template-env (SMOCK_TEMPLATE_ENV): "SMOCK_DIR" starts with SMOCK_: smock's own variables cannot be listed
      ),
    )
  })
}
