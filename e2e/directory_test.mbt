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
            #|Content-Length: 12
            #|
            #|from aa.json
            #|---
            #|200 OK
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
      // No load errors: the startup entry, then listening.
      out.push("\{stopped.logs.length()} log entries")
    }
    inspect(
      out.join("\n---\n"),
      content=(
        #|404 Not Found
        #|Content-Length: 0
        #|
        #|
        #|---
        #|2 log entries
        #|---
        #|404 Not Found
        #|Content-Length: 0
        #|
        #|
        #|---
        #|2 log entries
        #|---
        #|404 Not Found
        #|Content-Length: 0
        #|
        #|
        #|---
        #|2 log entries
      ),
    )
  })
}
