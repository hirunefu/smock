// Seam 2 tests of rendering: `smock render` on a temporary definitions
// directory, and the Admin render operation, checked against the OpenAPI
// document (contract_test.mbt).

///|
/// The Mock `users` in a JSON file, with a Stub that has every kind of
/// condition and a header given an array, and in a YAML file a Stub that
/// answers from a body file.
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
      #|      "headers": { "Location": "/users/7", "Set-Cookie": ["a=1", "b=2"],
      #|        "Content-Type": "application/json" },
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
  exit_report(render_output(args, env~))
}

///|
/// `text`, a rendering as JSON, with the time and the seed it used, which
/// change from run to run unless they are given, as `<time>` and `<seed>`.
fn masked(text : String) -> String {
  // Where the value of `name` starts, after `"name":` and any space.
  let value_at = (text : String, name : String) => {
    text
    .find("\"\{name}\":")
    .map(start => {
      let mut from = start + name.length() + 3
      while from < text.length() && text[from] == ' ' {
        from += 1
      }
      from
    })
  }
  let mut text = text
  if value_at(text, "time") is Some(from) &&
    text[from + 1:].find("\"") is Some(length) {
    text = "\{text[:from + 1]}<time>\{text[from + 1 + length:]}"
  }
  if value_at(text, "seed") is Some(from) {
    let mut end = from
    while end < text.length() && text[end] >= '0' && text[end] <= '9' {
      end += 1
    }
    text = "\{text[:from]}<seed>\{text[end:]}"
  }
  text
}

///|
/// The time and the seed of a rendering: the values, when `given`, or
/// `<time>` and `<seed>` when they change from run to run.
fn time_and_seed(json : Json, time_given~ : Bool, seed_given~ : Bool) -> String {
  guard json is { "time": String(time), "seed": Number(seed, ..), .. } else {
    return "no time or seed"
  }
  let time = if time_given { time } else { "<time>" }
  let seed = if seed_given { seed.to_int64().to_string() } else { "<seed>" }
  "time \{time}, seed \{seed}"
}

///|
/// Runs `smock render <args>` until it exits, with only `env` as its
/// environment, and returns its exit status, stdout and stderr.
async fn render_output(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> (Int, String, String) {
  smock_output(["render", ..args], env~)
}

///|
async test "smock render prints the named Stub's status, headers and body for a sample request, with no failed conditions when it meets them all" {
  with_definitions(render_definitions, dir => {
    inspect(
      masked(
        render([
          "--dir",
          dir,
          "create-user",
          "--request",
          "\{dir}/samples/match.json",
        ]),
      ),
      content=(
        #|status 0
        #|{
        #|  "stub": "create-user",
        #|  "mock": "users",
        #|  "time": "<time>",
        #|  "seed": <seed>,
        #|  "responseIndex": null,
        #|  "variables": {},
        #|  "response": {
        #|    "status": 201,
        #|    "headers": [
        #|      {
        #|        "name": "Location",
        #|        "value": "/users/7"
        #|      },
        #|      {
        #|        "name": "Set-Cookie",
        #|        "value": "a=1"
        #|      },
        #|      {
        #|        "name": "Set-Cookie",
        #|        "value": "b=2"
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
        #|  "templateError": null,
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
      masked(
        render([
          "--dir",
          dir,
          "create-user",
          "--request",
          "\{dir}/samples/fail.json",
        ]),
      ),
      content=(
        #|status 0
        #|{
        #|  "stub": "create-user",
        #|  "mock": "users",
        #|  "time": "<time>",
        #|  "seed": <seed>,
        #|  "responseIndex": null,
        #|  "variables": {},
        #|  "response": {
        #|    "status": 201,
        #|    "headers": [
        #|      {
        #|        "name": "Location",
        #|        "value": "/users/7"
        #|      },
        #|      {
        #|        "name": "Set-Cookie",
        #|        "value": "a=1"
        #|      },
        #|      {
        #|        "name": "Set-Cookie",
        #|        "value": "b=2"
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
        #|  "templateError": null,
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
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[]}
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"from bodies\n","size":12,"truncated":false},"events":null},"failed":[]}
        #|status 0: {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"from bodies\n","size":12,"truncated":false},"events":null},"failed":[]}
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
        "\{matched.status}\n\{masked(matched.body)}\n\{failed.status}\n\{masked(failed.body)}",
        content=(
          #|200
          #|{"stub":"get-user","mock":"users","time":"<time>","seed":<seed>,"responseIndex":null,"variables":{},"response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"templateError":null,"failed":[],"warnings":[]}
          #|200
          #|{"stub":"create-user","mock":"users","time":"<time>","seed":<seed>,"responseIndex":null,"variables":{},"response":{"status":201,"headers":[{"name":"Location","value":"/users/7"},{"name":"Set-Cookie","value":"a=1"},{"name":"Set-Cookie","value":"b=2"},{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"id\":7}","size":8,"truncated":false},"events":null},"templateError":null,"failed":[{"condition":"query:dry","expected":"yes","actual":["no"]},{"condition":"header:x-api-key","expected":"secret","actual":[]},{"condition":"body","expected":{"json":{"name":"Zoë"}},"actual":[""]}],"warnings":[]}
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
      let (check_status, check_stdout, _) = collect_output(
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
      let json = @json.parse(stdout)
      // A static response depends on neither the time nor the seed, but
      // the rendering shows those it used.
      let same = rendered(json) == rendered(@json.parse(plain))
      let shown = time_and_seed(
        json,
        time_given=args.contains("--time"),
        seed_given=args.contains("--seed"),
      )
      out.push(
        "\{args.join(" ")}: status \{status}, same: \{same}, \{shown}\{stderr}",
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
        if response.status == 200 {
          let json = response.json()
          let shown = time_and_seed(
            json,
            time_given=query.contains("time="),
            seed_given=query.contains("seed="),
          )
          out.push("\{query}: 200 \{rendered(json)}, \{shown}")
        } else {
          out.push("\{query}: \{response.status} \{response.body}")
        }
      }
    })
    inspect(
      out.join("\n"),
      content=(
        #|--time 2026-10-12T14:30:05Z --seed 42: status 0, same: true, time 2026-10-12T14:30:05.000Z, seed 42
        #|--time 2026-10-12t16:30:05.123456+02:00: status 0, same: true, time 2026-10-12T14:30:05.123Z, seed <seed>
        #|--time 2024-02-29T23:59:60-00:30 --seed 9007199254740991: status 0, same: true, time 2024-03-01T00:30:00.000Z, seed 9007199254740991
        #|--seed 0: status 0, same: true, time <time>, seed 0
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
        #|?time=2026-10-12T14:30:05Z&seed=42: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[]}, time 2026-10-12T14:30:05.000Z, seed 42
        #|?time=2026-10-12T16%3A30%3A05%2B02%3A00: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[]}, time 2026-10-12T14:30:05.000Z, seed <seed>
        #|?seed=7&other=ignored: 200 {"stub":"get-user","mock":"users","response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"},{"name":"Accept-Ranges","value":"bytes"}],"body":{"encoding":"utf-8","data":"{\"id\":1,\"name\":\"Alice\"}\n","size":24,"truncated":false},"events":null},"failed":[]}, time <time>, seed 7
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
      #|Render a Stub's response for a sample request, as the Admin API render operation does, and print it as JSON: the time and the seed it used, the status, the headers and the body or events, rendered from the Stub's templates when it has them, and the Stub's conditions the sample fails, with expected and actual values. A Stub with responses renders the response the seed picks, or the one --response names, and the output shows its index. The output shows the values the Stub's variables would write, rendered against the sample's vars, and writes nothing. Exits with status 1 if the definitions directory is invalid, no Stub has the ID, the Stub has no response at the index given, or the sample request is not valid.
      #|
      #|Arguments:
      #|  stub-id  The ID of a Stub from the Definition files.
      #|
      #|Options:
      #|  -h, --help                       Show help information.
      #|  --dir <dir>                      The definitions directory, read as smock serve reads it. [env: SMOCK_DIR]
      #|  --body-file-dir <body-file-dir>  The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
      #|  --template-env <template-env>    The environment variables templates may read as env.NAME, separated by commas, such as REGION,API_BASE. Their values are read once, at startup. A listed value can show in responses, renderings and template error messages, so list only values that may be shown. A name is letters, digits and _, starting with a letter or _, and cannot start with SMOCK_. None by default. [env: SMOCK_TEMPLATE_ENV]
      #|  --request <request>              A file that holds the sample request as JSON: {method, path, query, headers, body, session, vars}, each optional.
      #|  --time <time>                    The time the sample request is received at, as an RFC 3339 date-time such as 2026-10-12T14:30:05Z. Default: now.
      #|  --seed <seed>                    The seed of the random source the rendering draws from, from 0 to 9007199254740991. Default: the Stub's fault.seed, or a fresh seed when it has none.
      #|  --response <response>            The index of the response to render among the Stub's responses, from 0. A Stub with response takes 0 only. Default: the response the seed picks.
      #|
    ),
  )
}

///|
/// A Mock `market` with a Stub of two weighted responses and a Stub with
/// `response`, each with its own seed, so that every rendering of them is
/// the same.
let weighted_definitions : Array[(String, String)] = [
  (
    "prices.json",
    (
      #|{ "mocks": [{ "name": "market" }],
      #|  "stubs": [
      #|    { "id": "get-prices", "mock": "market", "request": { "path": "/prices" },
      #|      "responses": [
      #|        { "weight": 9, "status": 200, "json": { "price": 101 } },
      #|        { "weight": 1, "status": 503, "headers": { "Retry-After": "5" },
      #|          "template": true, "json": { "error": "unavailable", "id": "${fake.uuid()}" } } ],
      #|      "fault": { "seed": 7 } },
      #|    { "id": "plain", "mock": "market", "request": { "path": "/plain" },
      #|      "response": { "status": 204 }, "fault": { "seed": 3 } } ] }
    ),
  ),
  ("samples/get.json", "{ \"path\": \"/prices\" }"),
]

///|
/// The seed, the response index and the response of a rendering, as one
/// line of JSON.
fn picked(json : Json) -> String {
  guard json is Object(members) else { return "not an object" }
  let out : Map[String, Json] = Map([])
  for key in ["seed", "responseIndex", "response"] {
    out[key] = members.get(key).unwrap_or(Json::string("absent"))
  }
  Json::object(out).stringify()
}

///|
async test "smock render --response and the Admin render operation's response parameter render the same given response, and refuse an index the Stub does not have" {
  with_definitions(weighted_definitions, dir => {
    let sample = "\{dir}/samples/get.json"
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let out = []
      for
        case in [
          ("get-prices", None),
          ("get-prices", Some("0")),
          ("get-prices", Some("1")),
          ("plain", None),
          ("plain", Some("0")),
        ] {
        let (id, index) = case
        let (args, query) = match index {
          Some(index) => (["--response=\{index}"], "?response=\{index}")
          None => ([], "")
        }
        let (status, stdout, stderr) = render_output(
          ["--dir", dir, id, "--request", sample, ..args],
        )
        let response = smock.render(id, sample~, query~)
        let from_cli = picked(@json.parse(stdout))
        let from_admin = picked(response.json())
        out.push(
          "\{[id, ..args].join(" ")}: render \{status}, admin \{response.status}, same: \{from_cli == from_admin}\{stderr}",
        )
        out.push("  \{from_cli}")
      }
      for
        case in [
          ("get-prices", "2"),
          ("plain", "1"),
          ("get-prices", "100"),
          ("get-prices", "-1"),
          ("get-prices", "x"),
        ] {
        let (id, index) = case
        out.push(
          render(["--dir", dir, id, "--request", sample, "--response=\{index}"])
          .trim_end(chars="\n")
          .to_owned(),
        )
        let response = smock.render(id, sample~, query="?response=\{index}")
        out.push("admin: \{response.status} \{response.body}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|get-prices: render 0, admin 200, same: true
          #|  {"seed":7,"responseIndex":1,"response":{"status":503,"headers":[{"name":"Retry-After","value":"5"},{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"error\":\"unavailable\",\"id\":\"491faadb-213a-4ae9-b52a-e618828349a6\"}","size":67,"truncated":false},"events":null}}
          #|get-prices --response=0: render 0, admin 200, same: true
          #|  {"seed":7,"responseIndex":0,"response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"price\":101}","size":13,"truncated":false},"events":null}}
          #|get-prices --response=1: render 0, admin 200, same: true
          #|  {"seed":7,"responseIndex":1,"response":{"status":503,"headers":[{"name":"Retry-After","value":"5"},{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"error\":\"unavailable\",\"id\":\"491faadb-213a-4ae9-b52a-e618828349a6\"}","size":67,"truncated":false},"events":null}}
          #|plain: render 0, admin 200, same: true
          #|  {"seed":3,"responseIndex":null,"response":{"status":204,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null}}
          #|plain --response=0: render 0, admin 200, same: true
          #|  {"seed":3,"responseIndex":null,"response":{"status":204,"headers":[],"body":{"encoding":"utf-8","data":"","size":0,"truncated":false},"events":null}}
          #|status 1
          #|stderr:
          #|smock render: the Stub "get-prices" has no response 2: its responses run from 0 to 1
          #|admin: 400 {"error":"invalid_request","message":"the Stub \"get-prices\" has no response 2: its responses run from 0 to 1","warnings":[]}
          #|status 1
          #|stderr:
          #|smock render: the Stub "plain" has no response 1: it has one response, whose index is 0
          #|admin: 400 {"error":"invalid_request","message":"the Stub \"plain\" has no response 1: it has one response, whose index is 0","warnings":[]}
          #|status 2
          #|stderr:
          #|smock render: invalid value "100" for --response: must be an integer from 0 to 99
          #|admin: 400 {"error":"invalid_request","message":"the response query parameter must be an integer from 0 to 99","warnings":[]}
          #|status 2
          #|stderr:
          #|smock render: invalid value "-1" for --response: must be an integer from 0 to 99
          #|admin: 400 {"error":"invalid_request","message":"the response query parameter must be an integer from 0 to 99","warnings":[]}
          #|status 2
          #|stderr:
          #|smock render: invalid value "x" for --response: must be an integer from 0 to 99
          #|admin: 400 {"error":"invalid_request","message":"the response query parameter must be an integer from 0 to 99","warnings":[]}
        ),
      )
    })
  })
}

///|
/// What a rendering says of Variables: the values the Stub would write, the
/// response index, the response and the template error, as one line of
/// JSON.
fn with_variables(json : Json) -> String {
  guard json is Object(members) else { return "not an object" }
  let out : Map[String, Json] = Map([])
  for key in ["variables", "responseIndex", "response", "templateError"] {
    out[key] = members.get(key).unwrap_or(Json::string("absent"))
  }
  Json::object(out).stringify()
}

///|
async test "smock render and the Admin render operation read the sample's vars, show the same variables, and neither read nor write the live Variables" {
  with_definitions(
    [
      ("shop.yaml", who_logged_in),
      (
        "samples/bob.json",
        (
          #|{ "method": "POST", "path": "/login", "body": "{\"user\":\"ann\"}",
          #|  "vars": { "user": "bob" } }
        ),
      ),
      (
        "samples/test-a.json",
        (
          #|{ "method": "POST", "path": "/login", "body": "{\"user\":\"ann\"}",
          #|  "session": "test-a" }
        ),
      ),
      (
        "samples/no-user.json",
        (
          #|{ "method": "POST", "path": "/login", "body": "{}",
          #|  "vars": { "user": "bob" } }
        ),
      ),
      ("samples/bad.json", "{ \"vars\": [\"user\"] }"),
    ],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        let login = (session : String, user : String) => {
          smock.send(
            "POST",
            "/login",
            headers=[baggage(session), ("Content-Type", "application/json")],
            body="{\"user\":\"\{user}\"}",
          )
        }
        // A live Variable of test-a, which no rendering reads.
        ignore(login("test-a", "carol"))
        let out = []
        for sample in ["bob", "test-a", "no-user"] {
          let file = "\{dir}/samples/\{sample}.json"
          let (status, stdout, stderr) = render_output([
            "--dir", dir, "login", "--request", file,
          ])
          let response = smock.render("login", sample=file)
          let from_cli = with_variables(@json.parse(stdout))
          let from_admin = with_variables(response.json())
          out.push(
            "\{sample}: render \{status}, admin \{response.status}, same: \{from_cli == from_admin}\{stderr}",
          )
          out.push("  \{from_cli}")
        }
        let bad = "\{dir}/samples/bad.json"
        out.push(
          render(["--dir", dir, "login", "--request", bad])
          .trim_end(chars="\n")
          .replace_all(old=dir, new="<dir>")
          .to_owned(),
        )
        let response = smock.render("login", sample=bad)
        out.push("admin: \{response.status} \{response.body}")
        // The live Variables are as the request left them.
        out.push(
          "test-a logs in as dave: \{login("test-a", "dave").split("\n").last().unwrap()}",
        )
        inspect(
          out.join("\n"),
          content=(
            #|bob: render 0, admin 200, same: true
            #|  {"variables":{"user":"ann","previous":"bob"},"responseIndex":null,"response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"user\":\"ann\",\"previous\":\"bob\"}","size":31,"truncated":false},"events":null},"templateError":null}
            #|test-a: render 0, admin 200, same: true
            #|  {"variables":{"user":"ann","previous":null},"responseIndex":null,"response":{"status":200,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"user\":\"ann\",\"previous\":null}","size":30,"truncated":false},"events":null},"templateError":null}
            #|no-user: render 0, admin 200, same: true
            #|  {"variables":{},"responseIndex":null,"response":{"status":500,"headers":[{"name":"Content-Type","value":"application/json"}],"body":{"encoding":"utf-8","data":"{\"error\":\"template failed\",\"stub\":\"login\",\"at\":\"/variables/user\",\"message\":\"body.user is missing\"}","size":98,"truncated":false},"events":null},"templateError":{"at":"/variables/user","message":"body.user is missing"}}
            #|status 1
            #|stderr:
            #|smock render: the sample request <dir>/samples/bad.json is not valid: /vars: must be an object
            #|admin: 400 {"error":"invalid_request","message":"the sample request is not valid: /vars: must be an object","warnings":[]}
            #|test-a logs in as dave: {"user":"dave","previous":"carol"}
          ),
        )
      })
    },
  )
}
