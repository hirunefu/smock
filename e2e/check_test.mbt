///|
/// Runs `smock check <args>` with only `env` as its environment until it
/// exits, and renders its exit status, then what it wrote to stdout and,
/// if anything, to stderr.
async fn check(
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> String {
  build.wait()
  let result = @async.with_timeout_opt(patience_ms, () => {
    @process.collect_output(
      binary,
      ["check", ..args],
      extra_env=env,
      inherit_env=false,
    )
  })
  guard result is Some((status, stdout, stderr)) else {
    fail("smock check did not exit in time")
  }
  let out = "status \{status}\n\{stdout.text()}"
  match stderr.text() {
    "" => out
    err => "\{out}stderr:\n\{err}"
  }
}

///|
/// A Definition file that declares the Mock `users` and one Stub of it,
/// `get-user`.
let users_file : String =
  #|{ "mocks": [{ "name": "users" }],
  #|  "stubs": [{ "id": "get-user", "mock": "users",
  #|    "request": { "method": "GET", "path": "/users/1" },
  #|    "response": { "status": 200, "body": "{\"id\":1}" } }] }

///|
async test "smock check exits 0 and prints nothing when the definitions directory is valid" {
  with_definitions(
    [
      ("10-users.json", users_file),
      (
        "20-orders.json",
        (
          #|{ "version": 1, "mocks": [{ "name": "orders" }],
          #|  "stubs": [{ "id": "list-orders", "mock": "orders",
          #|    "response": { "status": 200 } }] }
        ),
      ),
    ],
    dir => inspect(check([dir]), content="status 0\n"),
  )
}

///|
async test "smock check prints every problem, one line each with the file and JSON Pointer, and exits 1" {
  with_definitions(
    [
      ("10-users.json", users_file),
      (
        "20-orders.json",
        (
          #|{ "mocks": [{ "name": "users" }],
          #|  "stubs": [
          #|    { "id": "get-user", "mock": "orders", "response": { "status": 200 } },
          #|    { "id": "list", "mock": "users", "request": { "path": "users" },
          #|      "response": { "status": 99, "bodyFile": "list.json" } },
          #|    { "id": "x", "mock": "users", "respnose": { "status": 200 } } ] }
        ),
      ),
      ("30-version.json", "{ \"version\": 2 }"),
      ("40-broken.json", "{ \"mocks\": "),
    ],
    dir => {
      inspect(
        check([dir]),
        content=(
          #|status 1
          #|20-orders.json: /mocks/0/name: the Mock name "users" is already declared at 10-users.json: /mocks/0/name
          #|20-orders.json: /stubs/0/id: the Stub ID "get-user" is already used at 10-users.json: /stubs/0/id
          #|20-orders.json: /stubs/0/mock: no file declares the Mock "orders"
          #|20-orders.json: /stubs/1/request/path: must start with /
          #|20-orders.json: /stubs/1/response/status: must be an integer from 200 to 599
          #|20-orders.json: /stubs/1/response/bodyFile: is not supported yet
          #|20-orders.json: /stubs/2/respnose: is not a known field
          #|20-orders.json: /stubs/2: needs "response"
          #|30-version.json: /version: must be 1, the only format version
          #|40-broken.json: not valid JSON: Unexpected end of file
          #|
        ),
      )
    },
  )
}

///|
async test "smock check reads the definitions directory by the rules smock serve uses" {
  with_definitions(
    [
      ("users.json", users_file),
      // Not Definition files, so never parsed: a dot entry, a file in a
      // subdirectory and a file with another name.
      (".hidden.json", "not JSON"),
      ("..data/linked.json", "not JSON"),
      ("sub/nested.json", "not JSON"),
      ("notes.txt", "not JSON"),
      // A Definition file reached through a symlink, as in a ConfigMap
      // volume.
      ("..data/orders.json", "{ \"mocks\": [{ \"name\": \"users\" }] }"),
    ],
    dir => {
      @fs.symlink(target="..data/orders.json", "\{dir}/orders.json")
      inspect(
        check([dir]),
        content=(
          #|status 1
          #|users.json: /mocks/0/name: the Mock name "users" is already declared at orders.json: /mocks/0/name
          #|
        ),
      )
    },
  )
}

///|
async test "smock check names the body-file subdirectory as smock serve does, by flag or SMOCK_BODY_FILE_DIR" {
  with_definitions(
    [
      ("users.json", users_file),
      ("bodies/a.json", "{}"),
      ("files/b.json", "{}"),
    ],
    dir => {
      @fs.chmod("\{dir}/bodies/a.json", 0o000)
      let out = [
        check([dir]),
        check(["--body-file-dir", "bodies", dir]),
        check([dir], env={ "SMOCK_BODY_FILE_DIR": "bodies" }),
        check(["--body-file-dir", "../bodies", dir]),
      ]
      inspect(
        out.join("---\n").replace_all(old=dir, new="<dir>"),
        content=(
          #|status 0
          #|---
          #|status 1
          #|bodies/a.json: cannot be read: OSError("@fs.open(): \"<dir>/bodies/a.json\": Permission denied")
          #|---
          #|status 1
          #|bodies/a.json: cannot be read: OSError("@fs.open(): \"<dir>/bodies/a.json\": Permission denied")
          #|---
          #|status 2
          #|stderr:
          #|smock check: invalid value "../bodies" for --body-file-dir (SMOCK_BODY_FILE_DIR): must be a relative path inside the definitions directory
          #|
        ),
      )
    },
  )
}

///|
async test "smock check needs the definitions directory as its argument" {
  inspect(
    check([]),
    content=(
      #|status 2
      #|stderr:
      #|error: 'dir' requires at least 1 values but only 0 were provided
      #|
      #|Usage: smock check [options] <dir>
      #|
      #|Check a definitions directory as smock serve would load it. Prints every problem, one per line, and exits with status 1 if there is any.
      #|
      #|Arguments:
      #|  dir  The definitions directory.
      #|
      #|Options:
      #|  -h, --help                       Show help information.
      #|  --body-file-dir <body-file-dir>  The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
      #|
      #|
    ),
  )
}

///|
async test "smock check --help names its argument and its settings" {
  inspect(
    check(["--help"]),
    content=(
      #|status 0
      #|Usage: smock check [options] <dir>
      #|
      #|Check a definitions directory as smock serve would load it. Prints every problem, one per line, and exits with status 1 if there is any.
      #|
      #|Arguments:
      #|  dir  The definitions directory.
      #|
      #|Options:
      #|  -h, --help                       Show help information.
      #|  --body-file-dir <body-file-dir>  The body-file subdirectory of the definitions directory. [env: SMOCK_BODY_FILE_DIR] [default: files]
      #|
    ),
  )
}

///|
/// The exit status of `smock check <dir>`, and whether `smock serve` loads
/// `dir`.
async fn verdicts(dir : String) -> String {
  let checked = check([dir])
  let checked = checked[:checked.find("\n").unwrap_or(0)].to_owned()
  "check: \{checked}, serve: \{serve_verdict(["--dir", dir])}"
}

///|
async test "a definitions directory that passes smock check loads in smock serve, and one that fails does not" {
  let sets = [
    [("users.json", users_file)],
    [],
    [("users.json", users_file), ("orders.json", "{ \"stubs\": [] }")],
    [("users.json", users_file), ("again.json", users_file)],
    [("users.json", "{ \"version\": \"latest\" }")],
    [("users.json", "{ \"mocks\": [{ \"name\": \"users\", \"hosts\": [] }] }")],
  ]
  let out = []
  for files in sets {
    with_definitions(files, dir => out.push(verdicts(dir)))
  }
  // A missing directory gives an empty definition set; a file is not a
  // definitions directory.
  with_definitions([("users.json", users_file)], dir => {
    out.push(verdicts("\{dir}/missing"))
    out.push(verdicts("\{dir}/users.json"))
  })
  inspect(
    out.join("\n"),
    content=(
      #|check: status 0, serve: serves
      #|check: status 0, serve: serves
      #|check: status 0, serve: serves
      #|check: status 1, serve: exits with status 1
      #|check: status 1, serve: exits with status 1
      #|check: status 1, serve: exits with status 1
      #|check: status 0, serve: serves
      #|check: status 1, serve: exits with status 1
    ),
  )
}
