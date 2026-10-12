///|
/// A Definition file declaring one Stub of Mock `m` that answers `GET path`
/// with 200 and `body`.
fn stub_file(id : String, path : String, body : String) -> String {
  (
    $|{ "stubs": [{ "id": "\{id}", "mock": "m",
    $|  "request": { "method": "GET", "path": "\{path}" },
    $|  "response": { "status": 200, "body": "\{body}" } }] }
  )
}

///|
async test "Definition files are the regular top-level .json files, symlinks followed, dot entries skipped, in byte-wise name order" {
  with_definitions(
    [
      ("mocks.json", "{ \"mocks\": [{ \"name\": \"m\" }] }"),
      // Byte-wise, aa.json comes before b.json, so its Stub is tried first.
      ("b.json", stub_file("b", "/order", "from b.json")),
      ("aa.json", stub_file("aa", "/order", "from aa.json")),
      // A ConfigMap volume: the visible name is a symlink into ..data.
      ("..data/linked.json", stub_file("linked", "/linked", "via a symlink")),
      // Neither a dot entry, nor a file in a subdirectory, nor a file with
      // another name is a Definition file, so these are never parsed.
      (".hidden.json", "not JSON"),
      ("..data/unlinked.json", "not JSON"),
      ("sub/nested.json", "not JSON"),
      ("files/body.json", "not JSON"),
      ("notes.txt", "not JSON"),
      ("stubs.json.bak", "not JSON"),
      ("dir.json/inner.json", "not JSON"),
    ],
    dir => {
      @fs.symlink(target="..data/linked.json", "\{dir}/linked.json")
      @fs.symlink(target="missing.json", "\{dir}/dangling.json")
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        inspect(
          smock.get("/order") + "\n---\n" + smock.get("/linked"),
          content=(
            #|200 OK
            #|Smock-Mock: m; via=default
            #|Content-Length: 12
            #|
            #|from aa.json
            #|---
            #|200 OK
            #|Smock-Mock: m; via=default
            #|Content-Length: 13
            #|
            #|via a symlink
          ),
        )
      })
    },
  )
}

///|
/// `stub_file` written in YAML.
fn yaml_stub_file(id : String, path : String, body : String) -> String {
  (
    $|stubs:
    $|  - id: \{id}
    $|    mock: m
    $|    request: { method: GET, path: \{path} }
    $|    response: { status: 200, body: \{body} }
  )
}

///|
async test "YAML and JSON Definition files mix in one directory, in byte-wise name order whatever their extension" {
  with_definitions(
    [
      ("mocks.yml", "mocks: [{ name: m }]\n"),
      // Byte-wise, a.yaml < a.yml < b.json, so a.yaml's Stub is tried first.
      ("a.yml", yaml_stub_file("a-yml", "/first", "from a.yml")),
      ("b.json", stub_file("b-json", "/first", "from b.json")),
      ("a.yaml", yaml_stub_file("a-yaml", "/first", "from a.yaml")),
      // And c.json < c.yml.
      ("c.yml", yaml_stub_file("c-yml", "/second", "from c.yml")),
      ("c.json", stub_file("c-json", "/second", "from c.json")),
      // Not Definition files, so never parsed.
      (".hidden.yaml", "not: [YAML"),
      ("sub/nested.yml", "not: [YAML"),
      ("stubs.yaml.bak", "not: [YAML"),
    ],
    dir => {
      let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
        inspect(
          smock.get("/first") + "\n---\n" + smock.get("/second"),
          content=(
            #|200 OK
            #|Smock-Mock: m; via=default
            #|Content-Length: 11
            #|
            #|from a.yaml
            #|---
            #|200 OK
            #|Smock-Mock: m; via=default
            #|Content-Length: 11
            #|
            #|from c.json
          ),
        )
      })
    },
  )
}

///|
async test "a missing or empty definitions directory, or none at all, gives an empty definition set" {
  with_definitions([], dir => {
    let runs = [
      ["--dir", dir, "--port", "0"],
      ["--dir", "\{dir}/missing", "--port", "0"],
      ["--port", "0"],
    ]
    let out = []
    for args in runs {
      let stopped = with_smock(args, smock => out.push(smock.get("/anything")))
      // No load errors: the startup entry, the random seed, listening on
      // the admin port, the self-signed certificate, listening on the
      // plain and the TLS port, then the start and end of the drain.
      out.push("\{stopped.logs.length()} log entries")
    }
    inspect(
      out.join("\n---\n"),
      content=(
        #|404 Not Found
        #|Content-Type: application/json
        #|Smock-Mock: default; via=default
        #|Content-Length: 27
        #|
        #|{"error":"no Stub matched"}
        #|---
        #|8 log entries
        #|---
        #|404 Not Found
        #|Content-Type: application/json
        #|Smock-Mock: default; via=default
        #|Content-Length: 27
        #|
        #|{"error":"no Stub matched"}
        #|---
        #|8 log entries
        #|---
        #|404 Not Found
        #|Content-Type: application/json
        #|Smock-Mock: default; via=default
        #|Content-Length: 27
        #|
        #|{"error":"no Stub matched"}
        #|---
        #|8 log entries
      ),
    )
  })
}
