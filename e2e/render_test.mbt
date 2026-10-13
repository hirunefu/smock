// Seam 2 tests of rendering: `smock render` on a temporary definitions
// directory, and the Admin render operation, checked against the OpenAPI
// document (contract_test.mbt).

///|
/// The Mock `users` in a JSON file, with a Stub that has every kind of
/// condition, and in a YAML file a Stub that answers from a body file.
let render_definitions : Array[(String, String)] = [
  (
    "10-users.json",
    (
      #|{ "mocks": [{ "name": "users", "hosts": ["users.example.com"] }],
      #|  "stubs": [{ "id": "create-user", "mock": "users",
      #|    "request": { "method": "POST", "path": "/users",
      #|      "query": { "dry": "yes" },
      #|      "headers": { "X-Api-Key": "secret" },
      #|      "body": { "json": { "name": "Zoë" } } },
      #|    "response": { "status": 201,
      #|      "headers": { "Location": "/users/7", "Content-Type": "application/json" },
      #|      "body": "{\"id\":7}" } }] }
    ),
  ),
  (
    "20-users.yaml",
    (
      #|stubs:
      #|  - id: get-user
      #|    mock: users
      #|    request: { method: GET, path: /users/1 }
      #|    response:
      #|      status: 200
      #|      headers: { Content-Type: application/json }
      #|      bodyFile: users/1.json
    ),
  ),
  ("files/users/1.json", "{\"id\":1,\"name\":\"Alice\"}\n"),
  // Sample requests. A subdirectory holds no Definition files.
  (
    "samples/match.json",
    (
      #|{ "method": "POST", "path": "/users", "query": { "dry": "yes" },
      #|  "headers": { "X-Api-Key": "secret" }, "body": "{\"name\": \"Zoë\"}" }
    ),
  ),
  (
    "samples/fail.json",
    (
      #|{ "method": "PUT", "path": "/users",
      #|  "headers": { "x-api-key": ["wrong", "also wrong"] }, "body": "{}" }
    ),
  ),
  ("samples/user.json", "{ \"path\": \"/users/1\" }"),
]

///|
/// Runs `smock render <args>` until it exits, with only `env` as its
/// environment, and renders its exit status, then what it wrote to stdout
/// and, if anything, to stderr.
async fn render(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> String {
  let (status, stdout, stderr) = render_output(args, env~)
  let out = "status \{status}\n\{stdout}"
  match stderr {
    "" => out
    err => "\{out}stderr:\n\{err}"
  }
}

///|
/// Runs `smock render <args>` until it exits, with only `env` as its
/// environment, and returns its exit status, stdout and stderr.
async fn render_output(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> (Int, String, String) {
  build.wait()
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(
      binary,
      ["render", ..args],
      extra_env=env,
      inherit_env=false,
    )
  })
  guard result is Some((status, stdout, stderr)) else {
    fail("smock render did not exit in time")
  }
  (status, stdout.text(), stderr.text())
}

///|
async test "smock render prints the named Stub's status, headers and body for a sample request, with no failed conditions when it meets them all" {
  with_definitions(render_definitions, dir => {
    inspect(
      render([
        "--dir",
        dir,
        "create-user",
        "--request",
        "\{dir}/samples/match.json",
      ]),
      content=(
        #|status 0
        #|{
        #|  "stub": "create-user",
        #|  "mock": "users",
        #|  "response": {
        #|    "status": 201,
        #|    "headers": [
        #|      {
        #|        "name": "Location",
        #|        "value": "/users/7"
        #|      },
        #|      {
        #|        "name": "Content-Type",
        #|        "value": "application/json"
        #|      }
        #|    ],
        #|    "body": {
        #|      "encoding": "utf-8",
        #|      "data": "{\"id\":7}",
        #|      "size": 8,
        #|      "truncated": false
        #|    },
        #|    "events": null
        #|  },
        #|  "failed": []
        #|}
        #|
      ),
    )
  })
}

///|
async test "smock render still renders the Stub when the sample fails its conditions, and lists them with expected and actual values" {
  with_definitions(render_definitions, dir => {
    inspect(
      render([
        "--dir",
        dir,
        "create-user",
        "--request",
        "\{dir}/samples/fail.json",
      ]),
      content=(
        #|status 0
        #|{
        #|  "stub": "create-user",
        #|  "mock": "users",
        #|  "response": {
        #|    "status": 201,
        #|    "headers": [
        #|      {
        #|        "name": "Location",
        #|        "value": "/users/7"
        #|      },
        #|      {
        #|        "name": "Content-Type",
        #|        "value": "application/json"
        #|      }
        #|    ],
        #|    "body": {
        #|      "encoding": "utf-8",
        #|      "data": "{\"id\":7}",
        #|      "size": 8,
        #|      "truncated": false
        #|    },
        #|    "events": null
        #|  },
        #|  "failed": [
        #|    {
        #|      "condition": "method",
        #|      "expected": "POST",
        #|      "actual": [
        #|        "PUT"
        #|      ]
        #|    },
        #|    {
        #|      "condition": "query:dry",
        #|      "expected": "yes",
        #|      "actual": []
        #|    },
        #|    {
        #|      "condition": "header:x-api-key",
        #|      "expected": "secret",
        #|      "actual": [
        #|        "wrong",
        #|        "also wrong"
        #|      ]
        #|    },
        #|    {
        #|      "condition": "body",
        #|      "expected": {
        #|        "json": {
        #|          "name": "Zoë"
        #|        }
        #|      },
        #|      "actual": [
        #|        "{}"
        #|      ]
        #|    }
        #|  ]
        #|}
        #|
      ),
    )
  })
}

///|
/// The body of the rendering `smock render` prints, without the replica
/// and the warnings, as one line of JSON.
fn rendered(json : Json) -> String {
  guard json is Object(members) else { return "not an object" }
  let out : Map[String, Json] = Map([])
  for key in ["stub", "mock", "response", "failed"] {
    out[key] = members.get(key).unwrap_or(Json::null())
  }
  Json::object(out).stringify()
}

///|
async test "smock render reads the directory as smock serve does: body files from the body-file subdirectory, YAML files, and SMOCK_DIR" {
  with_definitions(render_definitions, dir => {
    write(dir, "bodies/users/1.json", "from bodies\n")
    let sample = "\{dir}/samples/user.json"
    let out = []
    for
      run in [
        (["--dir", dir, "get-user", "--request", sample], Map([])),
        (
          [
            "--dir", dir, "get-user", "--request", sample, "--body-file-dir", "bodies",
          ],
          Map([]),
        ),
        (
          ["get-user", "--request", sample],
          { "SMOCK_DIR": dir, "SMOCK_BODY_FILE_DIR": "bodies" },
        ),
      ] {
      let (args, env) = run
      let (status, stdout, stderr) = render_output(args, env~)
      out.push("status \{status}: \{rendered(@json.parse(stdout))}\{stderr}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[]}
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"from bodies\n","size":12,"truncated":false},"events":null},"failed":[]}
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"from bodies\n","size":12,"truncated":false},"events":null},"failed":[]}
      ),
    )
  })
}

///|
/// Renders the Stub `id` for the sample in the file `sample` through the
/// Admin API render operation, with `query` after the path, and checks the
/// response against the OpenAPI document.
async fn Smock::render(
  self : Smock,
  id : String,
  sample? : String,
  body? : String,
  query? : String = "",
  token? : String? = Some(test_token),
) -> AdminResponse {
  let body = match (sample, body) {
    (Some(file), _) => Some(@fs.read_file(file).text())
    (None, body) => body
  }
  let path = "/v1/stubs/\{@percent.encode(id)}/render\{query}"
  let response = self.admin("POST", path, body?, token~)
  response
}

///|
async test "smock render and the Admin render operation give the same rendered response and failed conditions for the same files and sample" {
  with_definitions(render_definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for
        case in [
          ("create-user", "match"),
          ("create-user", "fail"),
          ("get-user", "user"),
          ("get-user", "match"),
        ] {
        let (id, sample) = case
        let file = "\{dir}/samples/\{sample}.json"
        let (status, stdout, _) = render_output([
          "--dir", dir, id, "--request", file,
        ])
        let response = smock.render(id, sample=file)
        let from_cli = rendered(@json.parse(stdout))
        let from_admin = rendered(response.json())
        out.push(
          "\{id} for \{sample}: render \{status}, admin \{response.status}, same: \{from_cli == from_admin}",
        )
      }
      inspect(
        out.join("\n"),
        content=(
          #|create-user for match: render 0, admin 200, same: true
          #|create-user for fail: render 0, admin 200, same: true
          #|get-user for user: render 0, admin 200, same: true
          #|get-user for match: render 0, admin 200, same: true
        ),
      )
    })
  })
}

///|
async test "the Admin render operation renders against the definitions the replica serves now, after a reload too" {
  with_definitions(render_definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let sample = "\{dir}/samples/user.json"
      let brief = (response : AdminResponse) => {
        guard response.json() is Object(body) else { return response.body }
        match body.get("response") {
          Some(Object(rendered)) =>
            "\{response.status} \{rendered.get("body").unwrap_or(Json::null()).stringify()}"
          _ =>
            "\{response.status} \{body.get("message").unwrap_or(Json::null()).stringify()}"
        }
      }
      let out = [brief(smock.render("get-user", sample~))]
      let before = smock.status()
      write(dir, "files/users/1.json", "Bob")
      @fs.remove("\{dir}/10-users.json")
      write(
        dir, "10-users.json", "{ \"mocks\": [{ \"name\": \"users\" }], \"stubs\": [] }",
      )
      let after = smock.reloaded(before)
      out.push(last_reload(after))
      out.push(brief(smock.render("get-user", sample~)))
      out.push(brief(smock.render("create-user", sample~)))
      inspect(
        out.join("\n"),
        content=(
          #|200 {"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false}
          #|"swapped"
          #|200 {"encoding":"utf-8","data":"Bob","size":3,"truncated":false}
          #|404 "no Stub from the Definition files has the ID \"create-user\""
        ),
      )
    })
  })
}

///|
async test "the Admin render operation answers with the rendering, the failed conditions and the warnings" {
  with_definitions(render_definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let matched = smock.render("get-user", sample="\{dir}/samples/user.json")
      let failed = smock.render(
        "create-user",
        body="{ \"method\": \"POST\", \"path\": \"/users\", \"query\": { \"dry\": \"no\" } }",
      )
      inspect(
        "\{matched.status}\n\{matched.body}\n\{failed.status}\n\{failed.body}",
        content=(
          #|200
          #|{"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[],"warnings":[]}
          #|200
          #|{"stub":"create-user","mock":"users","response":{"status":201,"headers":[{"name":"Location","value":"/users/7"},{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":7}","size":8,"truncated":false},"events":null},"failed":[{"condition":"query:dry","expected":"yes","actual":["no"]},{"condition":"header:x-api-key","expected":"secret","actual":[]},{"condition":"body","expected":{"json":{"name":"Zoë"}},"actual":[""]}],"warnings":[]}
        ),
      )
    })
  })
}

///|
async test "an unknown Stub ID gets a clear error: smock render exits with status 1, the Admin render operation answers 404 unknown_stub" {
  with_definitions(render_definitions, dir => {
    let sample = "\{dir}/samples/user.json"
    let cli = render(["--dir", dir, "no-such-stub", "--request", sample])
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let admin = [
        smock.render("no-such-stub", sample~),
        smock.render("users", sample~),
        smock.render("get user/1", sample~),
      ]
      inspect(
        cli + "---\n" + admin.map(r => "\{r.status} \{r.body}").join("\n"),
        content=(
          #|status 1
          #|stderr:
          #|smock render: no Stub from the Definition files has the ID "no-such-stub"
          #|---
          #|404 {"error":"unknown_stub","message":"no Stub from the Definition files has the ID \"no-such-stub\"","warnings":[]}
          #|404 {"error":"unknown_stub","message":"no Stub from the Definition files has the ID \"users\"","warnings":[]}
          #|404 {"error":"unknown_stub","message":"no Stub from the Definition files has the ID \"get user/1\"","warnings":[]}
        ),
      )
    })
  })
}

///|
async test "the Admin render operation needs the bearer token" {
  with_definitions(render_definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let sample = "\{dir}/samples/user.json"
      let out = [
        smock.render("get-user", sample~, token=None),
        smock.render("get-user", sample~, token=Some("wrong")),
      ]
      inspect(
        out.map(r => "\{r.status} \{r.body}").join("\n"),
        content=(
          #|401 {"error":"unauthorized","message":"the Admin API needs Authorization: Bearer <token>","warnings":[]}
          #|401 {"error":"unauthorized","message":"the bearer token is wrong","warnings":[]}
        ),
      )
    })
  })
}

///|
async test "an invalid definitions directory gives the messages smock check gives, and smock render exits with status 1" {
  with_definitions(
    [
      ..render_definitions,
      (
        "30-broken.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [{ "id": "x", "mock": "orders", "response": { "status": 99 } }] }
        ),
      ),
    ],
    dir => {
      let (check_status, check_stdout, _) = @process.collect_output(
        binary,
        ["check", dir],
        inherit_env=false,
      )
      let (status, stdout, stderr) = render_output([
        "--dir",
        dir,
        "get-user",
        "--request",
        "\{dir}/samples/user.json",
      ])
      inspect(
        "check: status \{check_status}\n\{check_stdout.text()}render: status \{status}, stdout \{stdout.escape()}\n\{stderr}",
        content=(
          #|check: status 1
          #|30-broken.json: /mocks/0/name: the Mock name "users" is already declared at 10-users.json: /mocks/0/name
          #|30-broken.json: /stubs/0/response/status: must be an integer from 200 to 599
          #|30-broken.json: /stubs/0/mock: no file declares the Mock "orders"
          #|render: status 1, stdout ""
          #|30-broken.json: /mocks/0/name: the Mock name "users" is already declared at 10-users.json: /mocks/0/name
          #|30-broken.json: /stubs/0/response/status: must be an integer from 200 to 599
          #|30-broken.json: /stubs/0/mock: no file declares the Mock "orders"
          #|
        ),
      )
    },
  )
}

///|
async test "a malformed sample request gets a clear error: smock render exits with status 1, the Admin render operation answers 400" {
  with_definitions(
    [
      ..render_definitions,
      ("samples/not-json.json", "{ \"path\": "),
      ("samples/array.json", "[\"GET\", \"/users/1\"]"),
      ("samples/bad-path.json", "{ \"path\": \"users/1\" }"),
      ("samples/bad-header.json", "{ \"headers\": { \"X-A\": 1 } }"),
      ("samples/unknown-field.json", "{ \"url\": \"/users/1\" }"),
    ],
    dir => {
      let samples = [
        "not-json", "array", "bad-path", "bad-header", "unknown-field", "missing",
      ]
      let out = []
      for sample in samples {
        out.push(
          render([
            "--dir",
            dir,
            "get-user",
            "--request",
            "\{dir}/samples/\{sample}.json",
          ]).replace_all(old=dir, new="<dir>"),
        )
      }
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        for sample in samples[:samples.length() - 1] {
          let response = smock.render(
            "get-user",
            sample="\{dir}/samples/\{sample}.json",
          )
          out.push("\{response.status} \{response.body}\n")
        }
        let empty = smock.render("get-user")
        out.push("\{empty.status} \{empty.body}\n")
      })
      inspect(
        out.join(""),
        content=(
          #|status 1
          #|stderr:
          #|smock render: the sample request <dir>/samples/not-json.json is not valid JSON: Unexpected end of file
          #|status 1
          #|stderr:
          #|smock render: the sample request <dir>/samples/array.json is not valid: must be a JSON object
          #|status 1
          #|stderr:
          #|smock render: the sample request <dir>/samples/bad-path.json is not valid: /path: must be a string that starts with /
          #|status 1
          #|stderr:
          #|smock render: the sample request <dir>/samples/bad-header.json is not valid: /headers/X-A: must be a string or an array of strings
          #|status 1
          #|stderr:
          #|smock render: the sample request <dir>/samples/unknown-field.json is not valid: /url: is not a known field
          #|status 1
          #|stderr:
          #|smock render: cannot read the sample request <dir>/samples/missing.json: no such file
          #|400 {"error":"malformed_json","message":"the body is not valid JSON: Unexpected end of file","warnings":[]}
          #|400 {"error":"invalid_request","message":"the sample request is not valid: must be a JSON object","warnings":[]}
          #|400 {"error":"invalid_request","message":"the sample request is not valid: /path: must be a string that starts with /","warnings":[]}
          #|400 {"error":"invalid_request","message":"the sample request is not valid: /headers/X-A: must be a string or an array of strings","warnings":[]}
          #|400 {"error":"invalid_request","message":"the sample request is not valid: /url: is not a known field","warnings":[]}
          #|400 {"error":"invalid_request","message":"the body must be a sample request: a JSON object","warnings":[]}
          #|
        ),
      )
    },
  )
}

///|
async test "the time and the seed can be given to smock render and to the Admin render operation; invalid values are rejected" {
  with_definitions(render_definitions, dir => {
    let sample = "\{dir}/samples/user.json"
    let base = ["--dir", dir, "get-user", "--request", sample]
    let (_, plain, _) = render_output(base)
    let out = []
    for
      args in [
        ["--time", "2026-10-12T14:30:05Z", "--seed", "42"],
        ["--time", "2026-10-12t16:30:05.123456+02:00"],
        ["--time", "2024-02-29T23:59:60-00:30", "--seed", "9007199254740991"],
        ["--seed", "0"],
      ] {
      let (status, stdout, stderr) = render_output([..base, ..args])
      out.push(
        "\{args.join(" ")}: status \{status}, same: \{stdout == plain}\{stderr}",
      )
    }
    for
      args in [
        ["--request", sample, "--time", "2026-10-12 14:30:05"],
        ["--request", sample, "--time", "2026-10-12T14:30:05"],
        ["--request", sample, "--time", "2026-02-29T00:00:00Z"],
        ["--request", sample, "--time", "2026-10-12T24:00:00Z"],
        ["--request", sample, "--time", "yesterday"],
        ["--request", sample, "--seed", "9007199254740992"],
        ["--request", sample, "--seed=-1"],
        ["--request", ""],
      ] {
      out.push(
        render(["--dir", dir, "get-user", ..args])
        .trim_end(chars="\n")
        .to_owned(),
      )
    }
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      for
        query in [
          "?time=2026-10-12T14:30:05Z&seed=42", "?time=2026-10-12T16%3A30%3A05%2B02%3A00",
          "?seed=7&other=ignored", "?time=yesterday", "?time=2026-10-12T14:30:05",
          "?seed=1.5", "?seed=9007199254740992", "?seed=1&seed=2", "?time=%ZZ",
        ] {
        let response = smock.render("get-user", sample~, query~)
        out.push("\{query}: \{response.status} \{response.body}")
      }
    })
    inspect(
      out.join("\n"),
      content=(
        #|--time 2026-10-12T14:30:05Z --seed 42: status 0, same: true
        #|--time 2026-10-12t16:30:05.123456+02:00: status 0, same: true
        #|--time 2024-02-29T23:59:60-00:30 --seed 9007199254740991: status 0, same: true
        #|--seed 0: status 0, same: true
        #|status 2
        #|stderr:
        #|smock render: invalid value "2026-10-12 14:30:05" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
        #|status 2
        #|stderr:
        #|smock render: invalid value "2026-10-12T14:30:05" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
        #|status 2
        #|stderr:
        #|smock render: invalid value "2026-02-29T00:00:00Z" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
        #|status 2
        #|stderr:
        #|smock render: invalid value "2026-10-12T24:00:00Z" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
        #|status 2
        #|stderr:
        #|smock render: invalid value "yesterday" for --time: must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z
        #|status 2
        #|stderr:
        #|smock render: invalid value "9007199254740992" for --seed: must be an integer from 0 to 9007199254740991
        #|status 2
        #|stderr:
        #|smock render: invalid value "-1" for --seed: must be an integer from 0 to 9007199254740991
        #|status 2
        #|stderr:
        #|smock render: invalid value "" for --request: must not be empty
        #|?time=2026-10-12T14:30:05Z&seed=42: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[],"warnings":[]}
        #|?time=2026-10-12T16%3A30%3A05%2B02%3A00: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[],"warnings":[]}
        #|?seed=7&other=ignored: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[],"warnings":[]}
        #|?time=yesterday: 400 {"error":"invalid_request","message":"the time query parameter must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z","warnings":[]}
        #|?time=2026-10-12T14:30:05: 400 {"error":"invalid_request","message":"the time query parameter must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z","warnings":[]}
        #|?seed=1.5: 400 {"error":"invalid_request","message":"the seed query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
        #|?seed=9007199254740992: 400 {"error":"invalid_request","message":"the seed query parameter must be an integer from 0 to 9007199254740991","warnings":[]}
        #|?seed=1&seed=2: 400 {"error":"invalid_request","message":"the seed query parameter is given more than once","warnings":[]}
        #|?time=%ZZ: 400 {"error":"invalid_request","message":"the time query parameter is not valid percent-encoded UTF-8","warnings":[]}
      ),
    )
  })
}

///|
async test "smock render needs the definitions directory, a Stub ID and a sample request" {
  with_definitions(render_definitions, dir => {
    let sample = "\{dir}/samples/user.json"
    let out = [
      render(["get-user", "--request", sample]),
      render(["--dir", dir, "get-user"]),
      render(["--dir", dir, "--request", sample]),
    ]
    let first_lines = out.map(text => {
      let lines = text.split("\n").collect()
      lines[:3].map(line => line.to_owned()).join("\n")
    })
    inspect(
      first_lines.join("\n---\n"),
      content=(
        #|status 2
        #|stderr:
        #|error: the following required argument was not provided: 'dir'
        #|---
        #|status 2
        #|stderr:
        #|error: the following required argument was not provided: 'request'
        #|---
        #|status 2
        #|stderr:
        #|error: 'stub-id' requires at least 1 values but only 0 were provided
      ),
    )
  })
}

///|
async test "smock render --help names its argument, its inputs and the settings it shares with smock serve" {
  inspect(
    render(["--help"]),
    content=(
      #|status 0
      #|Usage: smock render --dir <dir> --request <request> [options] <stub-id>
      #|
      #|Render a Stub's response for a sample request, as the Admin API render operation does, and print it as JSON: the status, the headers and the body, and the Stub's conditions the sample fails, with expected and actual values. Exits with status 1 if the definitions directory is invalid, no Stub has the ID, or the sample request is not valid.
      #|
      #|Arguments:
      #|  stub-id  The ID of a Stub from the Definition files.
      #|
      #|Options:
      #|  -h, --help                       Show help information.
      #|  --dir <dir>                      The definitions directory, read as smock serve reads it. [env: SMOCK_DIR]
      #|  --body-file-dir <body-file-dir>  The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
      #|  --request <request>              A file that holds the sample request as JSON: {method, path, query, headers, body, session}, each optional.
      #|  --time <time>                    The time the sample request is received at, as an RFC 3339 date-time such as 2026-10-12T14:30:05Z. Default: now.
      #|  --seed <seed>                    The seed of the random source the rendering draws from, from 0 to 9007199254740991. Default: a fresh seed.
      #|
    ),
  )
}
