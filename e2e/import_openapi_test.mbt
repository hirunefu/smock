// Seam 2 tests of `smock import-openapi`: the binary reads an OpenAPI
// document and writes a Definition file, which `smock serve` then serves
// like any other.

///|
/// Runs `smock import-openapi <args>` in the working directory `cwd` until
/// it exits, and renders its exit status, then what it wrote to stdout and,
/// if anything, to stderr, with `dir` written `<dir>`.
async fn import_openapi(
  args : Array[String],
  dir? : String = "",
  cwd? : String = ".",
) -> String {
  let report = exit_report(smock_output(["import-openapi", ..args], cwd~))
  if dir == "" {
    report
  } else {
    report.replace_all(old=dir, new="<dir>")
  }
}

///|
/// An OpenAPI document whose only operation is `listPets` on `GET /pets`,
/// with a `200` response and no content.
let petstore_document : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "paths": {
  #|    "/pets": {
  #|      "get": {
  #|        "operationId": "listPets",
  #|        "responses": { "200": { "description": "A list of pets" } }
  #|      }
  #|    }
  #|  }
  #|}

///|
/// Creates a temporary directory holding `api/petstore.json`, with
/// `document` in it, and an empty `defs/`, and runs `f` with its path.
async fn with_petstore(document : String, f : async (String) -> Unit) -> Unit {
  with_definitions([("api/petstore.json", document)], dir => {
    @fs.mkdir("\{dir}/defs")
    f(dir)
  })
}

///|
async test "smock import-openapi writes the Definition file, prints its summary line and exits 0" {
  with_petstore(petstore_document, dir => {
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/petstore.json",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.json: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/petstore.json").text(),
      content=(
        #|{
        #|  "version": 1,
        #|  "mocks": [
        #|    {
        #|      "name": "petstore"
        #|    }
        #|  ],
        #|  "stubs": [
        #|    {
        #|      "id": "petstore.listPets.200",
        #|      "mock": "petstore",
        #|      "request": {
        #|        "method": "GET",
        #|        "path": "/pets"
        #|      },
        #|      "response": {
        #|        "status": 200
        #|      }
        #|    }
        #|  ]
        #|}
        #|
      ),
    )
  })
}

///|
async test "smock import-openapi prints each warning as smock check does, naming the document as given, before the summary, and still exits 0" {
  with_petstore(
    (
      #|{
      #|  "openapi": "3.0.3",
      #|  "paths": {
      #|    "/pets": {
      #|      "get": {
      #|        "responses": {
      #|          "404": { "content": { "application/json": {} } },
      #|          "200": {}
      #|        }
      #|      }
      #|    },
      #|    "/pets/{petId}": {
      #|      "get": { "callbacks": { "onChange": {} }, "responses": { "200": {} } }
      #|    }
      #|  }
      #|}
    ),
    dir => {
      inspect(
        import_openapi(
          [
            "\{dir}/api/petstore.json",
            "--output",
            "\{dir}/defs/petstore.json",
            "--mock",
            "petstore",
          ],
          dir~,
        ),
        content=(
          #|status 0
          #|<dir>/api/petstore.json: /paths/~1pets~1{petId}/get/callbacks: warning: callbacks are not imported
          #|wrote <dir>/defs/petstore.json: 3 Stubs from 2 operations, 1 warnings
          #|
        ),
      )
    },
  )
}

///|
async test "smock import-openapi writes nothing and exits 1 when the document has an error or cannot be read, and says that it reads no URLs when the document names one" {
  with_petstore(
    (
      #|{ "swagger": "2.0", "paths": {} }
    ),
    dir => {
      inspect(
        import_openapi(
          [
            "\{dir}/api/petstore.json",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|<dir>/api/petstore.json: /swagger: Swagger 2.0 is not supported: convert the document to OpenAPI 3.0 first
          #|nothing written: 1 errors
          #|
        ),
      )
      inspect(@fs.exists("\{dir}/defs/petstore.json"), content="false")
      inspect(
        import_openapi(
          [
            "\{dir}/api/missing.json",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|<dir>/api/missing.json: cannot be read: no such file
          #|nothing written: 1 errors
          #|
        ),
      )
      inspect(
        import_openapi(
          [
            "https://example.com/api.json",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|https://example.com/api.json: cannot be read: no such file; smock reads no URLs: download the document first
          #|nothing written: 1 errors
          #|
        ),
      )
      inspect(@fs.exists("\{dir}/defs/petstore.json"), content="false")
    },
  )
}

///|
async test "smock import-openapi without --overwrite on refuses an existing --output before it reads the document, even one that does not exist, and leaves the file as it was" {
  with_petstore(petstore_document, dir => {
    @fs.write_file("\{dir}/defs/petstore.json", "hand-written")
    for document in ["api/petstore.json", "api/missing.json"] {
      inspect(
        import_openapi(
          [
            "\{dir}/\{document}",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|<dir>/defs/petstore.json: already exists, and smock import-openapi replaces a file only with --overwrite on
          #|nothing written: 1 errors
          #|
        ),
      )
    }
    inspect(
      @fs.read_file("\{dir}/defs/petstore.json").text(),
      content="hand-written",
    )
  })
}

///|
async test "smock import-openapi without --overwrite on keeps a file that appears at --output while it reads the document: nothing is written, that problem comes first, and the exit status is 1" {
  with_petstore(petstore_document, dir => {
    // A FIFO as the document holds smock in its read until the test has
    // made the output, after smock checked that it did not exist.
    let document = "\{dir}/api/fifo.json"
    let (status, _) = collect_output_merged("mkfifo", [document])
    inspect(status, content="0")
    let output = "\{dir}/defs/petstore.json"
    @async.with_task_group(group => {
      let run = group.spawn(() => {
        import_openapi(
          [document, "--mock", "petstore", "--output", output],
          dir~,
        )
      })
      // Opening the FIFO waits until smock opens it for reading.
      let fifo = @async.with_timeout_opt(patience_ms, () => {
        @fs.open(document, mode=WriteOnly)
      })
      guard fifo is Some(fifo) else { fail("smock did not read the document") }
      @fs.write_file(output, "hand-written")
      fifo.write(
        (
          #|{ "openapi": "3.1.0", "paths": {} }
        ),
      )
      fifo.close()
      inspect(
        run.wait(),
        content=(
          #|status 1
          #|<dir>/defs/petstore.json: cannot be written: it exists now, and is not replaced
          #|<dir>/api/fifo.json: /paths: warning: there is no operation to import: the file has no Stubs
          #|nothing written: 1 errors
          #|
        ),
      )
    })
    inspect(listing("\{dir}/defs"), content="petstore.json")
    inspect(@fs.read_file(output).text(), content="hand-written")
  })
}

///|
/// The names in `dir`, hidden ones included, in byte-wise order, one per
/// line, so that a test sees every file a run leaves behind.
async fn listing(dir : String) -> String {
  @fs.readdir(dir, sort=true).join("\n")
}

///|
async test "smock import-openapi --overwrite on replaces an existing --output, and leaves nothing else new in its directory" {
  with_petstore(petstore_document, dir => {
    @fs.write_file("\{dir}/defs/petstore.json", "an earlier import")
    @fs.write_file("\{dir}/defs/other.yaml", "version: 1\n")
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/petstore.json",
          "--overwrite",
          "on",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.json: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/petstore.json").text(),
      content=(
        #|{
        #|  "version": 1,
        #|  "mocks": [
        #|    {
        #|      "name": "petstore"
        #|    }
        #|  ],
        #|  "stubs": [
        #|    {
        #|      "id": "petstore.listPets.200",
        #|      "mock": "petstore",
        #|      "request": {
        #|        "method": "GET",
        #|        "path": "/pets"
        #|      },
        #|      "response": {
        #|        "status": 200
        #|      }
        #|    }
        #|  ]
        #|}
        #|
      ),
    )
    inspect(
      listing("\{dir}/defs"),
      content=(
        #|other.yaml
        #|petstore.json
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/other.yaml").text(),
      content="version: 1\n",
    )
  })
}

///|
async test "smock import-openapi rejects bad arguments as usage errors, on stderr with exit status 2" {
  let cases = [
    ["api.txt", "--mock", "m", "--output", "m.json"],
    ["api.JSON", "--mock", "m", "--output", "m.json"],
    ["api.YAML", "--mock", "m", "--output", "m.json"],
    ["api.json", "--mock", "", "--output", "m.json"],
    ["api.json", "--mock", "m", "--output", "m.txt"],
    ["api.json", "--mock", "m", "--output", "defs/.m.json"],
    ["api.json", "--mock", "m", "--output", "defs/.m.yaml"],
    ["api.json", "--mock", "m", "--output", "m.YAML"],
    ["api.json", "--mock", "m"],
    ["api.json", "--output", "m.json"],
    ["--mock", "m", "--output", "m.json"],
    ["api.json", "--mock", "m", "--output", "m.json", "--overwrite", "yes"],
    ["api.json", "--mock", "m", "--output", "m.json", "--overwrite", ""],
    ["api.json", "--mock", "m", "--output", "m.json", "--hosts", ":8080"],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "a.test,users:http",
    ],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "*.example.com",
    ],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "a.test,,b.test",
    ],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "a.test, b.test",
    ],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "pets.test,b.test,PETS.test.:8080",
    ],
    ["api.json", "--mock", "m", "--output", "m.json", "--hosts", "[::1],::1"],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "a.test", "--declare-mock",
      "off",
    ],
    [
      "api.json", "--mock", "m", "--output", "m.json", "--hosts", "", "--declare-mock",
      "off",
    ],
    ["api.json", "--mock", "m", "--output", "m.json", "--declare-mock", "yes"],
    ["api.json", "--mock", "m", "--output", "m.json", "--base-path", "v1"],
    ["api.json", "--mock", "m", "--output", "m.json", "--base-path", ""],
    ["api.json", "--mock", "m", "--output", "m.json", "--base-path", "/v1?x=1"],
    ["api.json", "--mock", "m", "--output", "m.json", "--base-path", "/v1#top"],
  ]
  let reports = []
  for args in cases {
    let (status, _, stderr) = smock_output(["import-openapi", ..args])
    let first = stderr.split("\n").next().unwrap_or("")
    reports.push("\{args.join(" ")}\n  status \{status}: \{first}")
  }
  inspect(
    reports.join("\n"),
    content=(
      #|api.txt --mock m --output m.json
      #|  status 2: smock import-openapi: invalid value "api.txt" for <document>: must name a .json, .yaml or .yml file
      #|api.JSON --mock m --output m.json
      #|  status 2: smock import-openapi: invalid value "api.JSON" for <document>: must name a .json, .yaml or .yml file
      #|api.YAML --mock m --output m.json
      #|  status 2: smock import-openapi: invalid value "api.YAML" for <document>: must name a .json, .yaml or .yml file
      #|api.json --mock  --output m.json
      #|  status 2: smock import-openapi: invalid value "" for --mock: must not be empty
      #|api.json --mock m --output m.txt
      #|  status 2: smock import-openapi: invalid value "m.txt" for --output: must name a .json, .yaml or .yml file
      #|api.json --mock m --output defs/.m.json
      #|  status 2: smock import-openapi: invalid value "defs/.m.json" for --output: must not name a file that starts with ., which smock skips
      #|api.json --mock m --output defs/.m.yaml
      #|  status 2: smock import-openapi: invalid value "defs/.m.yaml" for --output: must not name a file that starts with ., which smock skips
      #|api.json --mock m --output m.YAML
      #|  status 2: smock import-openapi: invalid value "m.YAML" for --output: must name a .json, .yaml or .yml file
      #|api.json --mock m
      #|  status 2: error: the following required argument was not provided: 'output'
      #|api.json --output m.json
      #|  status 2: error: the following required argument was not provided: 'mock'
      #|--mock m --output m.json
      #|  status 2: error: 'document' requires at least 1 values but only 0 were provided
      #|api.json --mock m --output m.json --overwrite yes
      #|  status 2: smock import-openapi: invalid value "yes" for --overwrite: must be on or off
      #|api.json --mock m --output m.json --overwrite 
      #|  status 2: smock import-openapi: invalid value "" for --overwrite: must be on or off
      #|api.json --mock m --output m.json --hosts :8080
      #|  status 2: smock import-openapi: invalid value ":8080" for --hosts: ":8080" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|api.json --mock m --output m.json --hosts a.test,users:http
      #|  status 2: smock import-openapi: invalid value "a.test,users:http" for --hosts: "users:http" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|api.json --mock m --output m.json --hosts *.example.com
      #|  status 2: smock import-openapi: invalid value "*.example.com" for --hosts: "*.example.com" must be an exact name: Hosts have no wildcards
      #|api.json --mock m --output m.json --hosts a.test,,b.test
      #|  status 2: smock import-openapi: invalid value "a.test,,b.test" for --hosts: "" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|api.json --mock m --output m.json --hosts a.test, b.test
      #|  status 2: smock import-openapi: invalid value "a.test, b.test" for --hosts: " b.test" must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080
      #|api.json --mock m --output m.json --hosts pets.test,b.test,PETS.test.:8080
      #|  status 2: smock import-openapi: invalid value "pets.test,b.test,PETS.test.:8080" for --hosts: "PETS.test.:8080" is the same Host as "pets.test": Hosts are compared in lower case, without the port and a trailing dot
      #|api.json --mock m --output m.json --hosts [::1],::1
      #|  status 2: smock import-openapi: invalid value "[::1],::1" for --hosts: "::1" is the same Host as "[::1]": Hosts are compared in lower case, without the port and a trailing dot
      #|api.json --mock m --output m.json --hosts a.test --declare-mock off
      #|  status 2: smock import-openapi: invalid value "a.test" for --hosts: must not be given with --declare-mock off: give the Hosts where the Mock is declared
      #|api.json --mock m --output m.json --hosts  --declare-mock off
      #|  status 2: smock import-openapi: invalid value "" for --hosts: must not be given with --declare-mock off: give the Hosts where the Mock is declared
      #|api.json --mock m --output m.json --declare-mock yes
      #|  status 2: smock import-openapi: invalid value "yes" for --declare-mock: must be on or off
      #|api.json --mock m --output m.json --base-path v1
      #|  status 2: smock import-openapi: invalid value "v1" for --base-path: must start with /
      #|api.json --mock m --output m.json --base-path 
      #|  status 2: smock import-openapi: invalid value "" for --base-path: must start with /
      #|api.json --mock m --output m.json --base-path /v1?x=1
      #|  status 2: smock import-openapi: invalid value "/v1?x=1" for --base-path: must not hold ? or #: a query or a fragment is not part of a path
      #|api.json --mock m --output m.json --base-path /v1#top
      #|  status 2: smock import-openapi: invalid value "/v1#top" for --base-path: must not hold ? or #: a query or a fragment is not part of a path
    ),
  )
}

///|
async test "smock import-openapi --help names its argument and its flags, none of which has a variable" {
  inspect(
    import_openapi(["--help"]),
    content=(
      #|status 0
      #|Usage: smock import-openapi --mock <mock> --output <output> [options] <document>
      #|
      #|Convert an OpenAPI 3.0, 3.1 or 3.2 document into a Definition file, once: it declares one Mock, unless --declare-mock is off, with a Stub for each response of each operation, and for each further named example, which matches the operation's method and path. The main response answers by default, and each other one when the request sends Smock-Status with its key as the document writes it, such as Smock-Status: 404. A further named example answers when the request sends Smock-Example with its name too, such as Smock-Example: dog. smock never reads OpenAPI when it serves. Prints every problem, one per line, as smock check does, then a summary line, and exits with status 1 if nothing was written.
      #|
      #|Arguments:
      #|  document  The OpenAPI document: a JSON file, whose name ends in .json, or a YAML file, read as YAML 1.2, whose name ends in .yaml or .yml.
      #|
      #|Options:
      #|  -h, --help                     Show help information.
      #|  --mock <mock>                  The name of the Mock the Definition file declares. Every Stub ID starts with it.
      #|  --hosts <hosts>                The Mock's Hosts, separated by commas, such as petstore.test,pets.internal:8080. None by default: the only Mock of a definitions directory is the Default Mock and needs none; with several Mocks, give its Hosts. The document's servers never become Hosts.
      #|  --declare-mock <declare-mock>  Whether the file declares the Mock: on or off. Off, it holds only the Stubs, for a Mock declared by hand in another file, such as to set default, noMatch or journal; --hosts is then refused. [default: on]
      #|  --ref-dir <ref-dir>            The directory that references to other files are followed in, by default the document's own. The document must lie under it. A reference that leads outside it, by its path or through a symlink, is an error: so a downloaded document cannot copy a file such as ../../.npmrc into the Definition file. smock never reads URLs.
      #|  --output <output>              The Definition file to write. Its name picks the format: .yaml or .yml writes YAML, with comments that map each Stub back to the document, and .json writes JSON. Its directory must exist. The file is written to a temporary file whose name starts with ., then renamed, so a smock that watches the directory never reads half a file.
      #|  --base-path <base-path>        A path to put in front of every path, such as /mock/petstore, to mount the API where the system under test calls it. It replaces the paths of the document's servers, which are then not read: / means no prefix. It must start with / and hold no ? or #. By default, the path of the first server of the operation, else of its Path Item, else of the document, is put in front.
      #|  --overwrite <overwrite>        Whether an existing --output is replaced: on or off. Off, an existing file is refused before the document is read, and nothing is written. Either way, a directory, a symlink, or the document or a file it refers to is refused. [default: off]
      #|
    ),
  )
}

///|
async test "smock serves an imported file like any other: its main status answers, and the Journal names the generated Stub" {
  with_petstore(petstore_document, dir => {
    let (status, _, _) = smock_output([
      "import-openapi",
      "\{dir}/api/petstore.json",
      "--mock",
      "petstore",
      "--output",
      "\{dir}/defs/petstore.json",
    ])
    inspect(status, content="0")
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      let response = smock.request("GET", "/pets", headers=[
        ("Host", "localhost"),
        baggage("imported"),
      ])
      inspect(status_line(response), content="HTTP/1.1 200 OK")
      match smock.journal(session="imported") {
        (200, Object({ "entries": Array([Object(entry)]), .. })) =>
          json_inspect(
            {
              "mock": entry.get("mock").unwrap_or(Json::null()),
              "stub": entry.get("stub").unwrap_or(Json::null()),
              "status": entry.get("status").unwrap_or(Json::null()),
            },
            content={
              "mock": "petstore",
              "stub": "petstore.listPets.200",
              "status": 200,
            },
          )
        (status, body) =>
          fail("unexpected Journal: \{status} \{body.stringify()}")
      }
    })
  })
}

///|
async test "smock import-openapi refuses a symlink, a directory, a missing directory and the document itself as --output, even with --overwrite on, before it reads the document, and leaves both directories as they were" {
  with_petstore(petstore_document, dir => {
    @fs.write_file("\{dir}/defs/real.json", "hand-written")
    @fs.symlink(target="real.json", "\{dir}/defs/link.json")
    @fs.symlink(target="missing.json", "\{dir}/defs/dangling.json")
    @fs.mkdir("\{dir}/defs/dir.json")
    @fs.symlink(target="../api", "\{dir}/defs/api-link")
    let before = "\{listing("\{dir}/defs")}\n--\n\{listing("\{dir}/api")}"
    // The first outputs are refused before the missing document is read.
    let cases = [
      ("defs/link.json", "api/missing.json"),
      ("defs/dangling.json", "api/missing.json"),
      ("defs/dir.json", "api/missing.json"),
      ("defs/nowhere/petstore.json", "api/missing.json"),
      ("defs/real.json/petstore.json", "api/missing.json"),
      ("api/petstore.json", "api/petstore.json"),
      ("defs/../api/petstore.json", "api/petstore.json"),
      ("defs/api-link/petstore.json", "api/petstore.json"),
    ]
    let reports = []
    for case in cases {
      let (output, document) = case
      let report = import_openapi(
        [
          "\{dir}/\{document}",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/\{output}",
          "--overwrite",
          "on",
        ],
        dir~,
      )
      reports.push("\{output}, from \{document}:\n\{report}")
    }
    inspect(
      reports.join(""),
      content=(
        #|defs/link.json, from api/missing.json:
        #|status 1
        #|<dir>/defs/link.json: is a symlink, and smock import-openapi replaces only a regular file
        #|nothing written: 1 errors
        #|defs/dangling.json, from api/missing.json:
        #|status 1
        #|<dir>/defs/dangling.json: is a symlink, and smock import-openapi replaces only a regular file
        #|nothing written: 1 errors
        #|defs/dir.json, from api/missing.json:
        #|status 1
        #|<dir>/defs/dir.json: is a directory, and smock import-openapi replaces only a regular file
        #|nothing written: 1 errors
        #|defs/nowhere/petstore.json, from api/missing.json:
        #|status 1
        #|<dir>/defs/nowhere/petstore.json: cannot be written: its directory does not exist
        #|nothing written: 1 errors
        #|defs/real.json/petstore.json, from api/missing.json:
        #|status 1
        #|<dir>/defs/real.json/petstore.json: cannot be written: its directory does not exist
        #|nothing written: 1 errors
        #|api/petstore.json, from api/petstore.json:
        #|status 1
        #|<dir>/api/petstore.json: is the document being imported, and smock import-openapi does not replace it with its own conversion
        #|nothing written: 1 errors
        #|defs/../api/petstore.json, from api/petstore.json:
        #|status 1
        #|<dir>/defs/../api/petstore.json: is the document being imported, and smock import-openapi does not replace it with its own conversion
        #|nothing written: 1 errors
        #|defs/api-link/petstore.json, from api/petstore.json:
        #|status 1
        #|<dir>/defs/api-link/petstore.json: is the document being imported, and smock import-openapi does not replace it with its own conversion
        #|nothing written: 1 errors
        #|
      ),
    )
    inspect(
      "\{listing("\{dir}/defs")}\n--\n\{listing("\{dir}/api")}",
      content=before,
    )
    inspect(
      @fs.read_file("\{dir}/defs/real.json").text(),
      content="hand-written",
    )
    assert_true(
      @fs.kind("\{dir}/defs/link.json", follow_symlink=false) is SymLink,
    )
    inspect(
      @fs.read_file("\{dir}/api/petstore.json").text() == petstore_document,
      content="true",
    )
  })
}

///|
/// The `petstore_document` with a summary, as the guide's quick start
/// shows it.
let petstore_with_summary : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "paths": {
  #|    "/pets": {
  #|      "get": {
  #|        "operationId": "listPets",
  #|        "summary": "List all pets",
  #|        "responses": { "200": { "description": "A list of pets" } }
  #|      }
  #|    }
  #|  }
  #|}

///|
async test "smock import-openapi writes a .yaml --output as YAML, with comments that map each Stub back to the document, and smock serves it" {
  with_petstore(petstore_with_summary, dir => {
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/petstore.yaml",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.yaml: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/petstore.yaml").text(),
      content=(
        #|# Generated by smock import-openapi from petstore.json
        #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
        #|# Do not edit: the next import replaces this file.
        #|version: 1
        #|mocks:
        #|  - name: petstore
        #|stubs:
        #|  # GET /pets, 200: List all pets
        #|  - id: petstore.listPets.200
        #|    mock: petstore
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|    response:
        #|      status: 200
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      let response = smock.request("GET", "/pets", headers=[
        ("Host", "localhost"),
        baggage("imported"),
      ])
      inspect(status_line(response), content="HTTP/1.1 200 OK")
      match smock.journal(session="imported") {
        (200, Object({ "entries": Array([Object(entry)]), .. })) =>
          json_inspect(
            entry.get("stub").unwrap_or(Json::null()),
            content="petstore.listPets.200",
          )
        (status, body) =>
          fail("unexpected Journal: \{status} \{body.stringify()}")
      }
    })
  })
}

///|
async test "smock import-openapi reads a .yaml document as YAML 1.2, so an unquoted status key such as 200: is the key \"200\"; a YAML problem is an error at its pointer, and nothing is written" {
  with_definitions(
    [
      (
        "api/petstore.yaml",
        (
          #|openapi: 3.1.0
          #|info:
          #|  title: Petstore
          #|  version: 1.0.0
          #|paths:
          #|  /pets:
          #|    get:
          #|      operationId: listPets
          #|      summary: List all pets
          #|      responses:
          #|        200:
          #|          description: A list of pets
          #|        404:
          #|          description: Not found
        ),
      ),
      (
        "api/aliases.yml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /pets:
          #|    get:
          #|      responses:
          #|        200: &ok { description: A list of pets }
          #|        404: *ok
        ),
      ),
    ],
    dir => {
      @fs.mkdir("\{dir}/defs")
      inspect(
        import_openapi(
          [
            "\{dir}/api/petstore.yaml",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.yaml",
          ],
          dir~,
        ),
        content=(
          #|status 0
          #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 1 operations, 0 warnings
          #|
        ),
      )
      inspect(
        @fs.read_file("\{dir}/defs/petstore.yaml").text(),
        content=(
          #|# Generated by smock import-openapi from petstore.yaml
          #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
          #|# Do not edit: the next import replaces this file.
          #|version: 1
          #|mocks:
          #|  - name: petstore
          #|stubs:
          #|  # GET /pets, 404: List all pets
          #|  - id: petstore.listPets.404
          #|    mock: petstore
          #|    request:
          #|      method: GET
          #|      path: /pets
          #|      headers:
          #|        Smock-Status: "404"
          #|    response:
          #|      status: 404
          #|  # GET /pets, 200: List all pets
          #|  - id: petstore.listPets.200
          #|    mock: petstore
          #|    request:
          #|      method: GET
          #|      path: /pets
          #|    response:
          #|      status: 200
          #|
        ),
      )
      inspect(
        import_openapi(
          [
            "\{dir}/api/aliases.yml",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/aliases.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|<dir>/api/aliases.yml: /paths/~1pets/get/responses/200: anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
          #|nothing written: 1 errors
          #|
        ),
      )
      inspect(@fs.exists("\{dir}/defs/aliases.json"), content="false")
    },
  )
}

///|
async test "smock import-openapi writes the same bytes from two working directories, with the document given by a relative and by an absolute path" {
  with_petstore(petstore_with_summary, dir => {
    inspect(
      import_openapi(
        [
          "api/petstore.json", "--mock", "petstore", "--output", "defs/relative.yaml",
        ],
        cwd=dir,
      ),
      content=(
        #|status 0
        #|wrote defs/relative.yaml: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "absolute.yaml",
        ],
        dir~,
        cwd="\{dir}/defs",
      ),
      content=(
        #|status 0
        #|wrote absolute.yaml: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    let relative = @fs.read_file("\{dir}/defs/relative.yaml").binary()
    let absolute = @fs.read_file("\{dir}/defs/absolute.yaml").binary()
    assert_eq(relative, absolute)
    assert_false(@utf8.decode_lossy(relative).contains(dir))
  })
}

///|
/// The guide's document for selecting responses: `getPet` on
/// `GET /pets/mine`, with a 200 and a 404.
let my_pet_document : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "paths": {
  #|    "/pets/mine": {
  #|      "get": {
  #|        "operationId": "getPet",
  #|        "responses": {
  #|          "200": { "description": "My pet" },
  #|          "404": { "description": "No pet" }
  #|        }
  #|      }
  #|    }
  #|  }
  #|}

///|
/// Imports `my_pet_document` into `<dir>/defs/petstore.yaml`, then runs
/// `f` with a smock that serves `<dir>/defs`.
async fn serving_my_pet(dir : String, f : async (Smock) -> Unit) -> Unit {
  inspect(
    import_openapi(
      [
        "\{dir}/api/petstore.json",
        "--mock",
        "petstore",
        "--output",
        "\{dir}/defs/petstore.yaml",
      ],
      dir~,
    ),
    content=(
      #|status 0
      #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 1 operations, 0 warnings
      #|
    ),
  )
  let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], f)
}

///|
/// What the Journal holds for `session`, in order: for each request,
/// its `Smock-Status` if it sent one, its `Smock-Example` when it sent one,
/// the status, the Stub that answered and where that Stub came from.
async fn Smock::answered(self : Smock, session : String) -> Json {
  let answered : Array[Json] = []
  for entry in self.journal_entries(session) {
    guard entry
      is {
        "request": Object({ "headers": Array(headers), .. }),
        "status": status,
        "stub": stub,
        "stubSource": source,
        ..
      } else {
      fail("unexpected entry: \{Json::object(entry).stringify()}")
    }
    let mut selector = Json::null()
    let mut example = None
    for header in headers {
      if header is Object({ "name": String(name), "value": value, .. }) {
        match name.to_lower() {
          "smock-status" => selector = value
          "smock-example" => example = Some(value)
          _ => ()
        }
      }
    }
    let request : Map[String, Json] = { "Smock-Status": selector }
    if example is Some(example) {
      request["Smock-Example"] = example
    }
    request["status"] = status
    request["stub"] = stub
    request["stubSource"] = source
    answered.push(Json::object(request))
  }
  Json::array(answered)
}

///|
/// The entries of the Journal of `session`, in order, each an object.
/// Fails when the Journal or an entry is not as smock writes it.
async fn Smock::journal_entries(
  self : Smock,
  session : String,
) -> Array[Map[String, Json]] {
  let entries = match self.journal(session~) {
    (200, Object({ "entries": Array(entries), .. })) => entries
    (status, body) => fail("unexpected Journal: \{status} \{body.stringify()}")
  }
  let objects = []
  for entry in entries {
    guard entry is Object(entry) else {
      fail("unexpected entry: \{entry.stringify()}")
    }
    objects.push(entry)
  }
  objects
}

///|
async test "smock serves an imported file with Smock-Status: a request gets the main response without it, the response it names with it, and the main one when no Stub names its value; the Journal names the Stub that answered" {
  with_petstore(my_pet_document, dir => {
    serving_my_pet(dir, smock => {
      let lines = []
      for selector in [None, Some("404"), Some("503")] {
        let headers = [("Host", "localhost"), baggage("selecting")]
        if selector is Some(key) {
          headers.push(("Smock-Status", key))
        }
        let response = smock.request("GET", "/pets/mine", headers~)
        lines.push(status_line(response))
      }
      inspect(
        lines.join("\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|HTTP/1.1 404 Not Found
          #|HTTP/1.1 200 OK
        ),
      )
      json_inspect(smock.answered("selecting"), content=[
        {
          "Smock-Status": null,
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
        {
          "Smock-Status": "404",
          "status": 404,
          "stub": "petstore.getPet.404",
          "stubSource": "file",
        },
        {
          "Smock-Status": "503",
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
      ])
    })
  })
}

///|
async test "a test whose requests cannot set Smock-Status selects the imported 404 for its Session only, with the guide's Ephemeral Stub that copies the generated response" {
  let ephemeral_stub =
    #|{"request":{"method":"GET","path":"/pets/mine"},"response":{"status":404}}
  let guide = @fs.read_file("docs/importing-openapi.md").text()
  if !guide.contains("-d '\{ephemeral_stub}'") {
    fail("docs/importing-openapi.md does not show the Ephemeral Stub as it is")
  }
  with_petstore(my_pet_document, dir => {
    serving_my_pet(dir, smock => {
      let added = smock.admin(
        "POST",
        "/v1/mocks/petstore/stubs",
        headers=[baggage("pet-missing")],
        body=ephemeral_stub,
      )
      inspect(added.status, content="201")
      let lines = []
      for session in [Some("pet-missing"), Some("other"), None] {
        let response = smock.request(
          "GET",
          "/pets/mine",
          headers=[("Host", "localhost"), ..session_headers(session)],
        )
        lines.push(
          "\{session.unwrap_or("no Session")}: \{status_line(response)}",
        )
      }
      inspect(
        lines.join("\n"),
        content=(
          #|pet-missing: HTTP/1.1 404 Not Found
          #|other: HTTP/1.1 200 OK
          #|no Session: HTTP/1.1 200 OK
        ),
      )
      json_inspect(smock.answered("pet-missing"), content=[
        {
          "Smock-Status": null,
          "status": 404,
          "stub": "eph-1",
          "stubSource": "ephemeral",
        },
      ])
      json_inspect(smock.answered("other"), content=[
        {
          "Smock-Status": null,
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
      ])
    })
  })
}

///|
async test "the guide's override in another file survives a re-import with --overwrite on, and smock check warns about each generated Stub it shadows, the Smock-Status one included" {
  let override_yaml =
    #|version: 1
    #|stubs:
    #|  - id: petstore.getPet.none
    #|    mock: petstore
    #|    priority: 1
    #|    request:
    #|      method: GET
    #|      path: /pets/mine
    #|    response:
    #|      status: 404
    #|      json:
    #|        message: You have no pet
    #|
  let guide = @fs.read_file("docs/importing-openapi.md").text()
  if !guide.contains(
      "```yaml\n# defs/petstore-overrides.yaml\n\{override_yaml}```\n",
    ) {
    fail("docs/importing-openapi.md does not show the override as it is")
  }
  with_petstore(my_pet_document, dir => {
    let args = [
      "api/petstore.json", "--mock", "petstore", "--output", "defs/petstore.yaml",
    ]
    inspect(
      import_openapi(args, cwd=dir),
      content=(
        #|status 0
        #|wrote defs/petstore.yaml: 2 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    @fs.write_file("\{dir}/defs/petstore-overrides.yaml", override_yaml)
    inspect(
      import_openapi([..args, "--overwrite", "on"], cwd=dir),
      content=(
        #|status 0
        #|wrote defs/petstore.yaml: 2 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    let checked = exit_report(smock_output(["check", "defs"], cwd=dir))
    inspect(
      checked,
      content=(
        #|status 0
        #|petstore.yaml: /stubs/0: warning: the Stub "petstore.getPet.404" can never match: the Stub "petstore.getPet.none" at petstore-overrides.yaml: /stubs/0 is tried first and matches every request this one would
        #|petstore.yaml: /stubs/1: warning: the Stub "petstore.getPet.200" can never match: the Stub "petstore.getPet.none" at petstore-overrides.yaml: /stubs/0 is tried first and matches every request this one would
        #|
      ),
    )
    // The guide shows the warnings as smock check prints them.
    let warnings = checked["status 0\n".length():].to_owned()
    if !guide.contains("```\n\{warnings}```\n") {
      fail("docs/importing-openapi.md does not show the warnings as they are")
    }
  })
}

///|
async test "smock serves an imported response's sampled body with its Content-Type" {
  with_petstore(
    (
      #|{
      #|  "openapi": "3.1.0",
      #|  "paths": {
      #|    "/pets/mine": {
      #|      "get": {
      #|        "operationId": "getPet",
      #|        "responses": {
      #|          "200": {
      #|            "content": {
      #|              "application/json": {
      #|                "schema": {
      #|                  "type": "object",
      #|                  "properties": {
      #|                    "id": { "type": "string", "format": "uuid" },
      #|                    "tags": { "type": "array", "items": { "type": "string" } }
      #|                  }
      #|                }
      #|              }
      #|            }
      #|          },
      #|          "404": {
      #|            "content": {
      #|              "application/problem+json": {
      #|                "schema": { "type": "object", "properties": { "title": { "const": "Not Found" } } }
      #|              }
      #|            }
      #|          }
      #|        }
      #|      }
      #|    },
      #|    "/version": {
      #|      "get": {
      #|        "responses": {
      #|          "200": { "content": { "text/plain; charset=utf-8": { "schema": { "const": "1.2.3" } } } }
      #|        }
      #|      }
      #|    }
      #|  }
      #|}
    ),
    dir => {
      inspect(
        import_openapi(
          [
            "\{dir}/api/petstore.json",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.yaml",
          ],
          dir~,
        ),
        content=(
          #|status 0
          #|wrote <dir>/defs/petstore.yaml: 3 Stubs from 2 operations, 0 warnings
          #|
        ),
      )
      let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
        let answers = []
        for
          request in [
            ("/pets/mine", None),
            ("/pets/mine", Some("404")),
            ("/version", None),
          ] {
          let headers = [("Host", "localhost")]
          if request.1 is Some(key) {
            headers.push(("Smock-Status", key))
          }
          answers.push(smock.request("GET", request.0, headers~))
        }
        inspect(
          answers.join("\n"),
          content=(
            #|HTTP/1.1 200 OK
            #|Content-Type: application/json
            #|Smock-Mock: petstore; via=default
            #|Content-Length: 63
            #|
            #|{"id":"00000000-0000-4000-8000-000000000000","tags":["string"]}
            #|HTTP/1.1 404 Not Found
            #|Content-Type: application/problem+json
            #|Smock-Mock: petstore; via=default
            #|Content-Length: 21
            #|
            #|{"title":"Not Found"}
            #|HTTP/1.1 200 OK
            #|Content-Type: text/plain; charset=utf-8
            #|Smock-Mock: petstore; via=default
            #|Content-Length: 5
            #|
            #|1.2.3
          ),
        )
      })
    },
  )
}

///|
/// The guide's document for paths with parameters: `getPetById` on
/// `GET /pets/{petId}`, written before `getMyPet` on `GET /pets/mine`.
let pets_by_id_document : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "paths": {
  #|    "/pets/{petId}": {
  #|      "get": { "operationId": "getPetById", "responses": { "200": {} } }
  #|    },
  #|    "/pets/mine": {
  #|      "get": { "operationId": "getMyPet", "responses": { "200": {} } }
  #|    }
  #|  }
  #|}

///|
async test "smock serves an imported file with a pattern: /pets/mine gets its own Stub, /pets/7 the pattern's, and /pets/a%2Fb neither" {
  with_petstore(pets_by_id_document, dir => {
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/petstore.yaml",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 2 operations, 0 warnings
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      let lines = []
      for path in ["/pets/mine", "/pets/7", "/pets/a%2Fb"] {
        let response = smock.request("GET", path, headers=[
          ("Host", "localhost"),
          baggage("patterns"),
        ])
        lines.push("\{path}: \{status_line(response)}")
      }
      inspect(
        lines.join("\n"),
        content=(
          #|/pets/mine: HTTP/1.1 200 OK
          #|/pets/7: HTTP/1.1 200 OK
          #|/pets/a%2Fb: HTTP/1.1 404 Not Found
        ),
      )
      json_inspect(smock.answered("patterns"), content=[
        {
          "Smock-Status": null,
          "status": 200,
          "stub": "petstore.getMyPet.200",
          "stubSource": "file",
        },
        {
          "Smock-Status": null,
          "status": 200,
          "stub": "petstore.getPetById.200",
          "stubSource": "file",
        },
        {
          "Smock-Status": null,
          "status": 404,
          "stub": null,
          "stubSource": null,
        },
      ])
    })
  })
}

///|
/// The guide's document for selecting examples: `getPet` on
/// `GET /pets/mine`, with a 200 whose examples are `cat` and then `dog`,
/// and a 404 whose examples are `missing` and then `gone`.
let pet_examples_document : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "paths": {
  #|    "/pets/mine": {
  #|      "get": {
  #|        "operationId": "getPet",
  #|        "responses": {
  #|          "200": {
  #|            "content": {
  #|              "application/json": {
  #|                "examples": {
  #|                  "cat": { "value": { "name": "Tom" } },
  #|                  "dog": { "value": { "name": "Rex" } }
  #|                }
  #|              }
  #|            }
  #|          },
  #|          "404": {
  #|            "content": {
  #|              "application/json": {
  #|                "examples": {
  #|                  "missing": { "value": { "message": "Pet not found" } },
  #|                  "gone": { "value": { "message": "Pet gone" } }
  #|                }
  #|              }
  #|            }
  #|          }
  #|        }
  #|      }
  #|    }
  #|  }
  #|}

///|
async test "smock serves an imported file with Smock-Example: alone it selects the main response's example, with Smock-Status the named response's, and a name that no Stub names falls through" {
  with_petstore(pet_examples_document, dir => {
    inspect(
      import_openapi(
        [
          "\{dir}/api/petstore.json",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/petstore.yaml",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.yaml: 4 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      let lines = []
      for
        selectors in [
          [],
          [("Smock-Example", "dog")],
          [("Smock-Status", "404")],
          [("Smock-Status", "404"), ("Smock-Example", "gone")],
          [("Smock-Status", "404"), ("Smock-Example", "lost")],
          [("Smock-Example", "lost")],
          [("Smock-Example", "gone")],
        ] {
        let response = smock.request(
          "GET",
          "/pets/mine",
          headers=[("Host", "localhost"), baggage("examples"), ..selectors],
        )
        let response_lines = response.split("\n").collect()
        let status = response_lines[0].trim_end(chars="\r")
        let body = response_lines[response_lines.length() - 1]
        lines.push("\{status}: \{body}")
      }
      inspect(
        lines.join("\n"),
        content=(
          #|HTTP/1.1 200 OK: {"name":"Tom"}
          #|HTTP/1.1 200 OK: {"name":"Rex"}
          #|HTTP/1.1 404 Not Found: {"message":"Pet not found"}
          #|HTTP/1.1 404 Not Found: {"message":"Pet gone"}
          #|HTTP/1.1 404 Not Found: {"message":"Pet not found"}
          #|HTTP/1.1 200 OK: {"name":"Tom"}
          #|HTTP/1.1 200 OK: {"name":"Tom"}
        ),
      )
      json_inspect(smock.answered("examples"), content=[
        {
          "Smock-Status": null,
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
        {
          "Smock-Status": null,
          "Smock-Example": "dog",
          "status": 200,
          "stub": "petstore.getPet.200.dog",
          "stubSource": "file",
        },
        {
          "Smock-Status": "404",
          "status": 404,
          "stub": "petstore.getPet.404",
          "stubSource": "file",
        },
        {
          "Smock-Status": "404",
          "Smock-Example": "gone",
          "status": 404,
          "stub": "petstore.getPet.404.gone",
          "stubSource": "file",
        },
        {
          "Smock-Status": "404",
          "Smock-Example": "lost",
          "status": 404,
          "stub": "petstore.getPet.404",
          "stubSource": "file",
        },
        {
          "Smock-Status": null,
          "Smock-Example": "lost",
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
        {
          "Smock-Status": null,
          "Smock-Example": "gone",
          "status": 200,
          "stub": "petstore.getPet.200",
          "stubSource": "file",
        },
      ])
    })
  })
}

///|
/// What the Journal holds for `session`, in order: for each request, the
/// Mock and the Stub that answered, and the status.
async fn Smock::answered_by(self : Smock, session : String) -> Json {
  let answered : Array[Json] = []
  for entry in self.journal_entries(session) {
    answered.push({
      "mock": entry.get("mock").unwrap_or(Json::null()),
      "stub": entry.get("stub").unwrap_or(Json::null()),
      "status": entry.get("status").unwrap_or(Json::null()),
    })
  }
  Json::array(answered)
}

///|
async test "a Mock imported with --hosts answers requests for its Hosts beside a hand-written Default Mock, and smock check accepts the directory" {
  with_petstore(petstore_document, dir => {
    @fs.write_file(
      "\{dir}/defs/users.yaml",
      (
        #|version: 1
        #|mocks:
        #|  - name: users
        #|    hosts:
        #|      - users.test
        #|    default: true
        #|stubs:
        #|  - id: users.pets
        #|    mock: users
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|    response:
        #|      status: 204
      ),
    )
    inspect(
      import_openapi(
        [
          "api/petstore.json", "--mock", "petstore", "--hosts", "petstore.test,pets.internal:8080",
          "--output", "defs/petstore.yaml",
        ],
        cwd=dir,
      ),
      content=(
        #|status 0
        #|wrote defs/petstore.yaml: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/petstore.yaml").text(),
      content=(
        #|# Generated by smock import-openapi from petstore.json
        #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore --hosts petstore.test,pets.internal:8080.
        #|# Do not edit: the next import replaces this file.
        #|version: 1
        #|mocks:
        #|  - name: petstore
        #|    hosts:
        #|      - petstore.test
        #|      - pets.internal:8080
        #|stubs:
        #|  # GET /pets, 200
        #|  - id: petstore.listPets.200
        #|    mock: petstore
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|    response:
        #|      status: 200
        #|
      ),
    )
    inspect(
      exit_report(smock_output(["check", "defs"], cwd=dir)),
      content=(
        #|status 0
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      for
        host in [
          "petstore.test", "PETS.internal:9090", "users.test", "other.test",
        ] {
        let _ = smock.request("GET", "/pets", headers=[
          ("Host", host),
          baggage("hosts"),
        ])
      }
      json_inspect(smock.answered_by("hosts"), content=[
        { "mock": "petstore", "stub": "petstore.listPets.200", "status": 200 },
        { "mock": "petstore", "stub": "petstore.listPets.200", "status": 200 },
        { "mock": "users", "stub": "users.pets", "status": 204 },
        { "mock": "users", "stub": "users.pets", "status": 204 },
      ])
    })
  })
}

///|
async test "a file imported with --declare-mock off holds only Stubs, for the Mock a hand-written file declares with its own settings: smock check accepts the directory, and smock serves both" {
  with_petstore(petstore_document, dir => {
    @fs.write_file(
      "\{dir}/defs/petstore-mock.yaml",
      (
        #|version: 1
        #|mocks:
        #|  - name: petstore
        #|    default: true
        #|    noMatch:
        #|      status: 501
      ),
    )
    inspect(
      import_openapi(
        [
          "api/petstore.json", "--mock", "petstore", "--declare-mock", "off", "--output",
          "defs/petstore.yaml",
        ],
        cwd=dir,
      ),
      content=(
        #|status 0
        #|wrote defs/petstore.yaml: 1 Stubs from 1 operations, 0 warnings
        #|
      ),
    )
    inspect(
      @fs.read_file("\{dir}/defs/petstore.yaml").text(),
      content=(
        #|# Generated by smock import-openapi from petstore.json
        #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore --declare-mock off.
        #|# Do not edit: the next import replaces this file.
        #|version: 1
        #|stubs:
        #|  # GET /pets, 200
        #|  - id: petstore.listPets.200
        #|    mock: petstore
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|    response:
        #|      status: 200
        #|
      ),
    )
    inspect(
      exit_report(smock_output(["check", "defs"], cwd=dir)),
      content=(
        #|status 0
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      let lines = []
      for target in ["/pets", "/owners"] {
        let response = smock.request("GET", target, headers=[
          ("Host", "localhost"),
          baggage("declared"),
        ])
        lines.push(status_line(response))
      }
      inspect(
        lines.join("\n"),
        content=(
          #|HTTP/1.1 200 OK
          #|HTTP/1.1 501 Not Implemented
        ),
      )
      json_inspect(smock.answered_by("declared"), content=[
        { "mock": "petstore", "stub": "petstore.listPets.200", "status": 200 },
        { "mock": "petstore", "stub": null, "status": 501 },
      ])
    })
  })
}

///|
/// The spec's example of servers: `getPetById` on `GET /pets/{petId}` and
/// `getMyPet` on `GET /pets/mine`, under the server
/// `https://api.example.com/v1`.
let pets_under_v1_document : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "servers": [{ "url": "https://api.example.com/v1" }],
  #|  "paths": {
  #|    "/pets/{petId}": {
  #|      "get": { "operationId": "getPetById", "responses": { "200": {} } }
  #|    },
  #|    "/pets/mine": {
  #|      "get": { "operationId": "getMyPet", "responses": { "200": {} } }
  #|    }
  #|  }
  #|}

///|
/// The status line of the answer to `GET <path>` for each of `paths`, one
/// per line, from `smock`.
async fn Smock::status_lines(self : Smock, paths : Array[String]) -> String {
  let lines = []
  for path in paths {
    let response = self.request("GET", path, headers=[("Host", "localhost")])
    lines.push("\{path}: \{status_line(response)}")
  }
  lines.join("\n")
}

///|
async test "smock serves an imported file under its server's path, and with --base-path under that path instead" {
  with_petstore(pets_under_v1_document, dir => {
    let document = "\{dir}/api/petstore.json"
    let output = "\{dir}/defs/petstore.yaml"
    inspect(
      import_openapi([document, "--mock", "petstore", "--output", output], dir~),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 2 operations, 0 warnings
        #|
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      inspect(
        smock.status_lines(["/v1/pets/mine", "/v1/pets/7", "/pets/7"]),
        content=(
          #|/v1/pets/mine: HTTP/1.1 200 OK
          #|/v1/pets/7: HTTP/1.1 200 OK
          #|/pets/7: HTTP/1.1 404 Not Found
        ),
      )
    })
    inspect(
      import_openapi(
        [
          document, "--mock", "petstore", "--output", output, "--base-path", "/mock/petstore",
          "--overwrite", "on",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 2 operations, 0 warnings
        #|
      ),
    )
    let file = @fs.read_file(output).text()
    inspect(
      file.split("\n").take(3).map(line => line.to_owned()).collect().join("\n"),
      content=(
        #|# Generated by smock import-openapi from petstore.json
        #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore --base-path /mock/petstore.
        #|# Do not edit: the next import replaces this file.
      ),
    )
    let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
      inspect(
        smock.status_lines([
          "/mock/petstore/pets/mine", "/mock/petstore/pets/7", "/v1/pets/7",
        ]),
        content=(
          #|/mock/petstore/pets/mine: HTTP/1.1 200 OK
          #|/mock/petstore/pets/7: HTTP/1.1 200 OK
          #|/v1/pets/7: HTTP/1.1 404 Not Found
        ),
      )
    })
  })
}

///|
async test "smock serves an imported response's documented headers, with their examples or samples, and skips those smock sets itself" {
  with_definitions(
    [
      (
        "api/petstore.yaml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /pets:
          #|    get:
          #|      operationId: listPets
          #|      responses:
          #|        200:
          #|          headers:
          #|            X-Rate-Limit:
          #|              schema: { type: integer }
          #|            X-Request-Id:
          #|              example: req-1
          #|            Content-Length:
          #|              schema: { type: integer }
          #|          content:
          #|            application/json:
          #|              example: [Tom]
          #|        429:
          #|          headers:
          #|            Retry-After:
          #|              example: 60
        ),
      ),
    ],
    dir => {
      @fs.mkdir("\{dir}/defs")
      inspect(
        import_openapi(
          [
            "\{dir}/api/petstore.yaml",
            "--mock",
            "petstore",
            "--output",
            "\{dir}/defs/petstore.yaml",
          ],
          dir~,
        ),
        content=(
          #|status 0
          #|wrote <dir>/defs/petstore.yaml: 2 Stubs from 1 operations, 0 warnings
          #|
        ),
      )
      let _ = with_smock(["--dir", "\{dir}/defs", "--port", "0"], smock => {
        let answers = []
        for status in [None, Some("429")] {
          let headers = [("Host", "localhost")]
          if status is Some(key) {
            headers.push(("Smock-Status", key))
          }
          answers.push(smock.request("GET", "/pets", headers~))
        }
        inspect(
          answers.join("\n"),
          content=(
            #|HTTP/1.1 200 OK
            #|X-Rate-Limit: 0
            #|X-Request-Id: req-1
            #|Content-Type: application/json
            #|Smock-Mock: petstore; via=default
            #|Content-Length: 7
            #|
            #|["Tom"]
            #|HTTP/1.1 429 Too Many Requests
            #|Retry-After: 60
            #|Smock-Mock: petstore; via=default
            #|Content-Length: 0
            #|
            #|
          ),
        )
      })
    },
  )
}

///|
/// An OpenAPI document split into files: `api/openapi.yaml`, whose Path
/// Item is in `api/paths/pets.yaml`, with a response in
/// `api/responses/pets.yaml` and one in `shared/errors.yaml`, outside
/// `api/`.
let split_documents : Array[(String, String)] = [
  (
    "api/openapi.yaml",
    (
      #|openapi: 3.1.0
      #|info:
      #|  title: Petstore
      #|  version: 1.0.0
      #|paths:
      #|  /pets:
      #|    $ref: paths/pets.yaml
    ),
  ),
  (
    "api/paths/pets.yaml",
    (
      #|get:
      #|  operationId: listPets
      #|  callbacks:
      #|    onEvent: {}
      #|  responses:
      #|    200:
      #|      $ref: ../responses/pets.yaml
      #|    404:
      #|      $ref: "../../shared/errors.yaml#/NotFound"
    ),
  ),
  (
    "api/responses/pets.yaml",
    (
      #|description: Pets
      #|content:
      #|  application/json:
      #|    example: [{ name: Rex }]
    ),
  ),
  (
    "shared/errors.yaml",
    (
      #|NotFound:
      #|  description: Not found
    ),
  ),
]

///|
async test "smock import-openapi follows references to other files under --ref-dir, by default the document's directory, and names each file as --ref-dir, as given, joined with its name under it" {
  with_definitions(split_documents, dir => {
    @fs.mkdir("\{dir}/defs")
    let args = [
      "api/openapi.yaml", "--mock", "petstore", "--output", "defs/petstore.yaml",
    ]
    inspect(
      import_openapi(args, cwd=dir),
      content=(
        #|status 1
        #|api/paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
        #|api/paths/pets.yaml: /get/responses/404/$ref: the file is outside --ref-dir: smock follows references only to files under it, by default the root document's directory
        #|nothing written: 1 errors
        #|
      ),
    )
    inspect(
      import_openapi([..args, "--ref-dir", "."], cwd=dir),
      content=(
        #|status 0
        #|./api/paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
        #|wrote defs/petstore.yaml: 2 Stubs from 1 operations, 1 warnings
        #|
      ),
    )
    let written = @fs.read_file("\{dir}/defs/petstore.yaml").text()
    inspect(
      written,
      content=(
        #|# Generated by smock import-openapi from openapi.yaml
        #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
        #|# Do not edit: the next import replaces this file.
        #|version: 1
        #|mocks:
        #|  - name: petstore
        #|stubs:
        #|  # GET /pets, 404
        #|  - id: petstore.listPets.404
        #|    mock: petstore
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|      headers:
        #|        Smock-Status: "404"
        #|    response:
        #|      status: 404
        #|  # GET /pets, 200
        #|  - id: petstore.listPets.200
        #|    mock: petstore
        #|    request:
        #|      method: GET
        #|      path: /pets
        #|    response:
        #|      status: 200
        #|      json:
        #|        - name: Rex
        #|
      ),
    )
    // The same import, with absolute paths, gives the same bytes.
    inspect(
      import_openapi(
        [
          "\{dir}/api/openapi.yaml",
          "--mock",
          "petstore",
          "--output",
          "\{dir}/defs/again.yaml",
          "--ref-dir",
          "\{dir}/",
        ],
        dir~,
      ),
      content=(
        #|status 0
        #|<dir>/api/paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
        #|wrote <dir>/defs/again.yaml: 2 Stubs from 1 operations, 1 warnings
        #|
      ),
    )
    assert_eq(@fs.read_file("\{dir}/defs/again.yaml").text(), written)
  })
}

///|
async test "smock import-openapi reports a referenced file that is missing, is not a regular file, or that a symlink leads outside --ref-dir, at each $ref that names it, and follows a symlink that stays inside" {
  with_definitions(
    [
      (
        "api/openapi.yaml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /a:
          #|    $ref: secret.yaml
          #|  /b:
          #|    $ref: linked/b.yaml
          #|  /c:
          #|    $ref: missing.yaml
          #|  /d:
          #|    $ref: dir.yaml
          #|  /e:
          #|    $ref: alias.yaml
          #|  /f:
          #|    get:
          #|      responses:
          #|        200:
          #|          $ref: "missing.yaml#/Ok"
        ),
      ),
      ("api/paths/e.yaml", "get: { responses: { 200: { description: OK } } }"),
      ("secret.yaml", "get: { responses: { 200: { description: secret } } }"),
      ("outside/b.yaml", "get: { responses: { 200: { description: B } } }"),
    ],
    dir => {
      @fs.mkdir("\{dir}/defs")
      @fs.mkdir("\{dir}/api/dir.yaml")
      @fs.symlink(target="../secret.yaml", "\{dir}/api/secret.yaml")
      @fs.symlink(target="../outside", "\{dir}/api/linked")
      @fs.symlink(target="paths/e.yaml", "\{dir}/api/alias.yaml")
      inspect(
        import_openapi(
          ["api/openapi.yaml", "--mock", "m", "--output", "defs/m.yaml"],
          cwd=dir,
        ),
        content=(
          #|status 1
          #|api/openapi.yaml: /paths/~1a/$ref: api/secret.yaml cannot be read: a symlink leads it outside --ref-dir
          #|api/openapi.yaml: /paths/~1b/$ref: api/linked/b.yaml cannot be read: a symlink leads it outside --ref-dir
          #|api/openapi.yaml: /paths/~1c/$ref: api/missing.yaml cannot be read: no such file
          #|api/openapi.yaml: /paths/~1d/$ref: api/dir.yaml cannot be read: not a regular file
          #|api/openapi.yaml: /paths/~1f/get/responses/200/$ref: api/missing.yaml cannot be read: no such file
          #|nothing written: 5 errors
          #|
        ),
      )
      inspect(listing("\{dir}/defs"), content="")
    },
  )
}

///|
async test "smock import-openapi refuses a document outside --ref-dir, by its path or through a symlink, and a --ref-dir that is not a directory, as usage errors, with exit status 2; . and .. in either are resolved" {
  with_definitions(split_documents, dir => {
    @fs.mkdir("\{dir}/defs")
    // A document under api/ by its path, but outside it by where it is.
    write(dir, "v1/openapi.yaml", split_documents[0].1)
    @fs.symlink(target="../v1", "\{dir}/api/v1")
    let cases = [
      ["api/openapi.yaml", "--ref-dir", "api/paths"],
      ["api/openapi.yaml", "--ref-dir", "shared"],
      ["api/v1/openapi.yaml", "--ref-dir", "api"],
      ["./api/../api/openapi.yaml", "--ref-dir", "api/paths/.."],
      ["api/openapi.yaml", "--ref-dir", "missing"],
      ["api/openapi.yaml", "--ref-dir", "api/openapi.yaml"],
      ["api/openapi.yaml", "--ref-dir", ""],
    ]
    let reports = []
    for args in cases {
      let (status, stdout, stderr) = smock_output(
        ["import-openapi", ..args, "--mock", "m", "--output", "defs/m.yaml"],
        cwd=dir,
      )
      reports.push("\{args.join(" ")}\n  status \{status}: \{stdout}\{stderr}")
    }
    inspect(
      reports.join(""),
      content=(
        #|api/openapi.yaml --ref-dir api/paths
        #|  status 2: smock import-openapi: invalid value "api/openapi.yaml" for <document>: must lie under --ref-dir "api/paths"
        #|api/openapi.yaml --ref-dir shared
        #|  status 2: smock import-openapi: invalid value "api/openapi.yaml" for <document>: must lie under --ref-dir "shared"
        #|api/v1/openapi.yaml --ref-dir api
        #|  status 2: smock import-openapi: invalid value "api/v1/openapi.yaml" for <document>: must lie under --ref-dir "api"
        #|./api/../api/openapi.yaml --ref-dir api/paths/..
        #|  status 1: api/paths/../paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
        #|api/paths/../paths/pets.yaml: /get/responses/404/$ref: the file is outside --ref-dir: smock follows references only to files under it, by default the root document's directory
        #|nothing written: 1 errors
        #|api/openapi.yaml --ref-dir missing
        #|  status 2: smock import-openapi: invalid value "missing" for --ref-dir: must name a directory
        #|api/openapi.yaml --ref-dir api/openapi.yaml
        #|  status 2: smock import-openapi: invalid value "api/openapi.yaml" for --ref-dir: must name a directory
        #|api/openapi.yaml --ref-dir 
        #|  status 2: smock import-openapi: invalid value "" for --ref-dir: must not be empty
        #|
      ),
    )
    inspect(listing("\{dir}/defs"), content="")
  })
}

///|
async test "smock import-openapi refuses a referenced document as --output, even with --overwrite on, and leaves it as it was" {
  with_definitions(split_documents, dir => {
    let before = @fs.read_file("\{dir}/api/responses/pets.yaml").text()
    inspect(
      import_openapi(
        [
          "api/openapi.yaml", "--mock", "petstore", "--ref-dir", ".", "--output",
          "api/responses/pets.yaml", "--overwrite", "on",
        ],
        cwd=dir,
      ),
      content=(
        #|status 1
        #|api/responses/pets.yaml: is one of the documents being imported, and smock import-openapi does not replace it with its own conversion
        #|./api/paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
        #|nothing written: 1 errors
        #|
      ),
    )
    assert_eq(@fs.read_file("\{dir}/api/responses/pets.yaml").text(), before)
    inspect(listing("\{dir}/api/responses"), content="pets.yaml")
  })
}
