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
      #|    "/pets/{petId}": { "get": { "responses": { "200": {} } } }
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
          #|<dir>/api/petstore.json: /paths/~1pets~1{petId}/get: warning: left out: paths with parameters are not imported yet
          #|wrote <dir>/defs/petstore.json: 2 Stubs from 1 operations, 1 warnings
          #|
        ),
      )
    },
  )
}

///|
async test "smock import-openapi writes nothing and exits 1 when the document has an error" {
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
      inspect(@fs.exists("\{dir}/defs/petstore.json"), content="false")
    },
  )
}

///|
async test "smock import-openapi refuses an existing --output before it reads the document, even one that does not exist, and leaves the file as it was" {
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
          #|<dir>/defs/petstore.json: already exists, and smock import-openapi does not replace a file
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
    ["api.json", "--mock", "m", "--output", "m.json", "--overwrite", "on"],
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
      #|api.json --mock m --output m.json --overwrite on
      #|  status 2: error: unexpected argument '--overwrite' found
    ),
  )
}

///|
async test "smock import-openapi --help names its argument and its flags, none of which has a variable" {
  inspect(
    import_openapi(["--help"]),
    content=(
      #|status 0
      #|Usage: smock import-openapi --mock <mock> --output <output> <document>
      #|
      #|Convert an OpenAPI 3.0, 3.1 or 3.2 document into a Definition file, once: it declares one Mock, with a Stub for each response of each operation, which matches the operation's method and path. The main response answers by default, and each other one when the request sends Smock-Status with its key as the document writes it, such as Smock-Status: 404. smock never reads OpenAPI when it serves. Prints every problem, one per line, as smock check does, then a summary line, and exits with status 1 if nothing was written.
      #|
      #|Arguments:
      #|  document  The OpenAPI document: a JSON file, whose name ends in .json, or a YAML file, read as YAML 1.2, whose name ends in .yaml or .yml.
      #|
      #|Options:
      #|  -h, --help         Show help information.
      #|  --mock <mock>      The name of the Mock the Definition file declares. Every Stub ID starts with it.
      #|  --output <output>  The Definition file to write. Its name picks the format: .yaml or .yml writes YAML, with comments that map each Stub back to the document, and .json writes JSON. It must not exist: the file is created new.
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
      inspect(
        response.split("\n").next().unwrap_or(""),
        content="HTTP/1.1 200 OK",
      )
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
async test "smock import-openapi writes nothing and exits 1 when the output cannot be written, and names that problem first" {
  with_petstore(
    (
      #|{
      #|  "openapi": "3.1.0",
      #|  "paths": {
      #|    "/pets": {
      #|      "get": {
      #|        "responses": {
      #|          "200": {},
      #|          "404": { "content": { "application/json": {} } }
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
            "\{dir}/nowhere/petstore.json",
          ],
          dir~,
        ),
        content=(
          #|status 1
          #|<dir>/nowhere/petstore.json: cannot be written: its directory does not exist
          #|nothing written: 1 errors
          #|
        ),
      )
    },
  )
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
      inspect(
        response.split("\n").next().unwrap_or(""),
        content="HTTP/1.1 200 OK",
      )
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
/// its `Smock-Status` if it sent one, the status, the Stub that answered
/// and where that Stub came from.
async fn Smock::answered(self : Smock, session : String) -> Json {
  match self.journal(session~) {
    (200, Object({ "entries": Array(entries), .. })) => {
      let answered : Array[Json] = []
      for entry in entries {
        guard entry
          is Object(
            {
              "request": Object({ "headers": Array(headers), .. }),
              "status": status,
              "stub": stub,
              "stubSource": source,
              ..
            }
          ) else {
          fail("unexpected entry: \{entry.stringify()}")
        }
        let mut selector = Json::null()
        for header in headers {
          if header is Object({ "name": String(name), "value": value, .. }) &&
            name.to_lower() == "smock-status" {
            selector = value
          }
        }
        answered.push({
          "Smock-Status": selector,
          "status": status,
          "stub": stub,
          "stubSource": source,
        })
      }
      Json::array(answered)
    }
    (status, body) => fail("unexpected Journal: \{status} \{body.stringify()}")
  }
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
        lines.push(response.split("\n").next().unwrap_or("").to_owned())
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
  with_petstore(my_pet_document, dir => {
    serving_my_pet(dir, smock => {
      let added = smock.admin(
        "POST",
        "/v1/mocks/petstore/stubs",
        headers=[baggage("pet-missing")],
        body=(
          #|{"request":{"method":"GET","path":"/pets/mine"},"response":{"status":404}}
        ),
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
          "\{session.unwrap_or("no Session")}: \{response.split("\n").next().unwrap_or("")}",
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
