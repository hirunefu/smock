///|
/// Converts `document`, a JSON OpenAPI document named `petstore.json`, into
/// a Definition file for the Mock `mock`, and renders what came out: every
/// problem, one per line, then the numbers of Stubs and operations and the
/// file, or `nothing written`.
fn import_json(document : String, mock? : String = "petstore") -> String {
  let options = @importopenapi.Options(
    root="petstore.json",
    mock~,
    output="defs/petstore.json",
  )
  rendered(
    @importopenapi.convert([("petstore.json", @utf8.encode(document))], options),
  )
}

///|
/// What `conversion` gave: its problems, one per line, then the numbers of
/// Stubs and operations and the file, or `nothing written`.
fn rendered(conversion : @importopenapi.Conversion) -> String {
  let out = StringBuilder()
  for problem in conversion.problems() {
    out.write_string(problem.to_string())
    out.write_char('\n')
  }
  match conversion {
    Converted(file~, stubs~, operations~, ..) => {
      out.write_string("\{stubs} Stubs from \{operations} operations\n")
      out.write_string(@utf8.decode_lossy(file))
    }
    Failed(_) => out.write_string("nothing written\n")
  }
  out.to_string()
}

///|
test "an operation at a path without parameters becomes one Stub that matches its method and exact path and answers its main status" {
  inspect(
    import_json(
      (
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
      ),
    ),
    content=(
      #|1 Stubs from 1 operations
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
}

///|
/// A document of the OpenAPI version `version`, given as JSON text, whose
/// only operation is `GET /pets`.
fn with_version(version : String) -> String {
  "{ \{version}, \"paths\": { \"/pets\": { \"get\": { \"responses\": { \"200\": {} } } } } }"
}

///|
/// The first line of what `import_json` renders.
fn first_line(rendering : String) -> String {
  rendering.split("\n").next().unwrap_or("").to_owned()
}

///|
test "OpenAPI 3.0, 3.1 and 3.2 are read, whatever the patch" {
  let versions = ["3.0.0", "3.0.3", "3.1.0", "3.1.1", "3.2.0", "3.2.17"].map(version => {
    "\{version}: \{first_line(import_json(with_version("\"openapi\": \"\{version}\"")))}"
  })
  inspect(
    versions.join("\n"),
    content=(
      #|3.0.0: 1 Stubs from 1 operations
      #|3.0.3: 1 Stubs from 1 operations
      #|3.1.0: 1 Stubs from 1 operations
      #|3.1.1: 1 Stubs from 1 operations
      #|3.2.0: 1 Stubs from 1 operations
      #|3.2.17: 1 Stubs from 1 operations
    ),
  )
}

///|
test "any other version is an error: a number says to quote it and give the patch, and Swagger 2.0 says to convert the document to 3.0 first" {
  let versions = [
    "\"openapi\": 3.1", "\"openapi\": \"3.1\"", "\"openapi\": \"3.3.0\"", "\"openapi\": \"2.0.0\"",
    "\"openapi\": \"3.1.0-rc1\"", "\"openapi\": \"v3.1.0\"", "\"openapi\": true",
    "\"swagger\": \"2.0\"", "\"swagger\": \"1.2\"", "\"openapi\": \"3.1.0\", \"swagger\": \"2.0\"",
    "\"info\": {}",
  ].map(version => import_json(with_version(version)))
  inspect(
    versions.join(""),
    content=(
      #|petstore.json: /openapi: must be a string such as "3.1.0": quote the version, and give its patch
      #|nothing written
      #|petstore.json: /openapi: must be a version 3.<minor>.<patch> of digits, such as "3.1.0"
      #|nothing written
      #|petstore.json: /openapi: not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2
      #|nothing written
      #|petstore.json: /openapi: not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2
      #|nothing written
      #|petstore.json: /openapi: must be a version 3.<minor>.<patch> of digits, such as "3.1.0"
      #|nothing written
      #|petstore.json: /openapi: must be a version 3.<minor>.<patch> of digits, such as "3.1.0"
      #|nothing written
      #|petstore.json: /openapi: must be a string such as "3.1.0"
      #|nothing written
      #|petstore.json: /swagger: Swagger 2.0 is not supported: convert the document to OpenAPI 3.0 first
      #|nothing written
      #|petstore.json: /swagger: not a version smock imports: it imports OpenAPI 3.0, 3.1 and 3.2
      #|nothing written
      #|petstore.json: /swagger: a document has "openapi" or "swagger", not both
      #|nothing written
      #|petstore.json: needs "openapi", the OpenAPI version, such as "3.1.0"
      #|nothing written
      #|
    ),
  )
}

///|
test "the document must be UTF-8 JSON, an object without a repeated key; a leading byte order mark is skipped" {
  let document = @utf8.encode(with_version("\"openapi\": \"3.1.0\""))
  let inputs : Array[Bytes] = [
    b"\xef\xbb\xbf" + document,
    b"{ \"openapi\": \"3.1.0\", \"x\": \"\xff\" }",
    b"{ \"openapi\": \"3.1.0\", ",
    b"[]",
    b"{ \"openapi\": \"3.1.0\", \"paths\": { \"/a\": {}, \"/a\": {} } }",
  ]
  let options = @importopenapi.Options(
    root="api.json",
    root_label="docs/api.json",
    mock="m",
    output="m.json",
  )
  let rendered = inputs.map(bytes => {
    first_line(rendered(@importopenapi.convert([("api.json", bytes)], options)))
  })
  inspect(
    rendered.join("\n"),
    content=(
      #|1 Stubs from 1 operations
      #|docs/api.json: not valid UTF-8
      #|docs/api.json: not valid JSON: Unexpected end of file
      #|docs/api.json: must be an object
      #|docs/api.json: /paths/~1a: duplicate key
    ),
  )
}

///|
/// A document of OpenAPI 3.2.0 with `paths`, given as JSON text.
fn with_paths(paths : String) -> String {
  "{ \"openapi\": \"3.2.0\", \"paths\": \{paths} }"
}

///|
/// The Stub IDs, methods and paths of the file that `import_json` renders,
/// one per line, after its problems, with the base path `base_path`, if
/// given. A pattern is written `pattern <it>`.
fn stubs_of(document : String, base_path? : String) -> String raise {
  let options = @importopenapi.Options(
    root="petstore.json",
    mock="petstore",
    output="defs/petstore.json",
    base_path?,
  )
  let conversion = @importopenapi.convert(
    [("petstore.json", @utf8.encode(document))],
    options,
  )
  let out = StringBuilder()
  for problem in conversion.problems() {
    out.write_string(problem.to_string())
    out.write_char('\n')
  }
  guard conversion is Converted(file~, ..) else {
    out.write_string("nothing written\n")
    return out.to_string()
  }
  let json = @json.parse(@utf8.decode_lossy(file)) catch {
    _ => fail("the file is not JSON")
  }
  guard json is Object({ "stubs": Array(stubs), .. }) else {
    fail("the file has no stubs")
  }
  for stub in stubs {
    guard stub
      is Object(
        {
          "id": String(id),
          "request": Object({ "method": String(meth), "path": path, .. }),
          "response": Object({ "status": Number(status, ..), .. }),
          ..
        }
      ) else {
      fail("unexpected Stub: \{stub.stringify()}")
    }
    let path = match path {
      String(path) => path
      Object({ "pattern": String(pattern), .. }) => "pattern \{pattern}"
      _ => fail("unexpected path: \{path.stringify()}")
    }
    out.write_string("\{id}: \{meth} \{path} -> \{status}\n")
  }
  out.to_string()
}

///|
test "every operation is imported, in document order: path keys, then methods in the order the Path Item writes them, each in upper case, with 3.2's query" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/b": {
          #|    "trace": { "responses": { "200": {} } },
          #|    "summary": "B",
          #|    "query": { "responses": { "200": {} } },
          #|    "get": { "responses": { "200": {} } },
          #|    "parameters": [],
          #|    "put": { "responses": { "200": {} } }
          #|  },
          #|  "/a": {
          #|    "post": { "responses": { "201": {} } },
          #|    "delete": { "responses": { "204": {} } },
          #|    "options": { "responses": { "200": {} } },
          #|    "head": { "responses": { "200": {} } },
          #|    "patch": { "responses": { "200": {} } }
          #|  }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.TRACE /b.200: TRACE /b -> 200
      #|petstore.QUERY /b.200: QUERY /b -> 200
      #|petstore.GET /b.200: GET /b -> 200
      #|petstore.PUT /b.200: PUT /b -> 200
      #|petstore.POST /a.201: POST /a -> 201
      #|petstore.DELETE /a.204: DELETE /a -> 204
      #|petstore.OPTIONS /a.200: OPTIONS /a -> 200
      #|petstore.HEAD /a.200: HEAD /a -> 200
      #|petstore.PATCH /a.200: PATCH /a -> 200
      #|
    ),
  )
}

///|
test "HEAD is answered only where the document has head" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{ "/a": { "get": { "responses": { "200": {} } } } }
        ),
      ),
    ),
    content=(
      #|petstore.GET /a.200: GET /a -> 200
      #|
    ),
  )
}

///|
test "3.2's additionalOperations are imported with their keys as written, at their place among the methods" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": {
          #|    "get": { "responses": { "200": {} } },
          #|    "additionalOperations": {
          #|      "COPY": { "operationId": "copyA", "responses": { "201": {} } },
          #|      "purge": { "responses": { "202": {} } },
          #|      "post": { "responses": { "200": {} } }
          #|    },
          #|    "delete": { "responses": { "204": {} } }
          #|  }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.GET /a.200: GET /a -> 200
      #|petstore.copyA.201: COPY /a -> 201
      #|petstore.purge /a.202: purge /a -> 202
      #|petstore.post /a.200: post /a -> 200
      #|petstore.DELETE /a.204: DELETE /a -> 204
      #|
    ),
  )
}

///|
test "an additionalOperations key that is not an HTTP token, or that names a method with its own field in upper case, is an error" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": {
          #|    "additionalOperations": {
          #|      "MY METHOD": { "responses": { "200": {} } },
          #|      "": { "responses": { "200": {} } },
          #|      "POST": { "responses": { "200": {} } },
          #|      "QUERY": { "responses": { "200": {} } }
          #|    }
          #|  },
          #|  "/b": { "additionalOperations": [] }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/additionalOperations/MY METHOD: a method must be an HTTP token, such as COPY
      #|petstore.json: /paths/~1a/additionalOperations/: a method must be an HTTP token, such as COPY
      #|petstore.json: /paths/~1a/additionalOperations/POST: the method POST has its own field, post, so it cannot be an additional operation
      #|petstore.json: /paths/~1a/additionalOperations/QUERY: the method QUERY has its own field, query, so it cannot be an additional operation
      #|petstore.json: /paths/~1b/additionalOperations: must be an object
      #|nothing written
      #|
    ),
  )
}

///|
test "a path without parameters becomes an exact path, percent-decoded as smock decodes request paths; x- keys under paths are ignored" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/caf%C3%A9/a%20b": { "get": { "responses": { "200": {} } } },
          #|  "/100%/%zz/%E2%82": { "get": { "responses": { "200": {} } } },
          #|  "/": { "get": { "responses": { "200": {} } } },
          #|  "x-internal": { "/ignored": {} }
          #|}
        ),
      ),
    ),
    // A shorter path comes first.
    content=(
      #|petstore.GET /.200: GET / -> 200
      #|petstore.GET /caf%C3%A9/a%20b.200: GET /café/a b -> 200
      #|petstore.GET /100%/%zz/%E2%82.200: GET /100%/%zz/� -> 200
      #|
    ),
  )
}

///|
test "a path key that does not start with /, has unbalanced braces or an empty {}, or holds ? or #, is an error" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "pets": { "get": { "responses": { "200": {} } } },
          #|  "/pets/{id": { "get": { "responses": { "200": {} } } },
          #|  "/pets/id}": { "get": { "responses": { "200": {} } } },
          #|  "/pets/{{id}}": { "get": { "responses": { "200": {} } } },
          #|  "/pets/{}": { "get": { "responses": { "200": {} } } },
          #|  "/pets?all": { "get": { "responses": { "200": {} } } },
          #|  "/pets#all": { "get": { "responses": { "200": {} } } },
          #|  "/ok": { "get": { "responses": { "200": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/pets: a path must start with /
      #|petstore.json: /paths/~1pets~1{id: a path has an unbalanced { or }
      #|petstore.json: /paths/~1pets~1id}: a path has an unbalanced { or }
      #|petstore.json: /paths/~1pets~1{{id}}: a path has an unbalanced { or }
      #|petstore.json: /paths/~1pets~1{}: a path has an empty {}: a parameter needs a name
      #|petstore.json: /paths/~1pets?all: a path must not hold ? or #: a query or a fragment is not part of it
      #|petstore.json: /paths/~1pets#all: a path must not hold ? or #: a query or a fragment is not part of it
      #|nothing written
      #|
    ),
  )
}

///|
test "when two operations' method and path conditions come out the same, as for exact paths that decode alike, the first in document order is kept and the later one is left out with a warning" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a%2Fb": { "get": { "operationId": "first", "responses": { "200": {} } } },
          #|  "/a/b": {
          #|    "get": { "operationId": "second", "responses": { "200": {} } },
          #|    "put": { "operationId": "third", "responses": { "200": {} } }
          #|  },
          #|  "/caf%c3%a9": { "get": { "operationId": "fourth", "responses": { "200": {} } } },
          #|  "/café": { "get": { "responses": { "200": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a~1b/get: warning: left out: GET "/a/b" is already answered by the operation at petstore.json: /paths/~1a%2Fb/get, which comes first
      #|petstore.json: /paths/~1café/get: warning: left out: GET "/café" is already answered by the operation at petstore.json: /paths/~1caf%c3%a9/get, which comes first
      #|petstore.fourth.200: GET /café -> 200
      #|petstore.first.200: GET /a/b -> 200
      #|petstore.third.200: PUT /a/b -> 200
      #|
    ),
  )
}

///|
/// The Stubs `stubs_of` gives for one `GET /r` operation with the
/// Responses Object `responses`, given as JSON text.
fn main_of(responses : String) -> String raise {
  stubs_of(
    with_paths(
      "{ \"/r\": { \"get\": { \"operationId\": \"r\", \"responses\": \{responses} } } }",
    ),
  )
}

///|
test "the main response is the lowest explicit 2xx code, then 2XX; else default, which answers 200; else the lowest explicit code from 300 to 599, then 3XX, 4XX and 5XX" {
  let cases = [
    "{ \"404\": {}, \"201\": {}, \"2XX\": {}, \"default\": {}, \"200\": {} }", "{ \"404\": {}, \"default\": {}, \"2XX\": {} }",
    "{ \"404\": {}, \"5XX\": {}, \"default\": {}, \"302\": {} }", "{ \"5XX\": {}, \"404\": {}, \"302\": {} }",
    "{ \"5XX\": {}, \"4XX\": {}, \"3XX\": {} }", "{ \"5XX\": {}, \"4XX\": {} }",
    "{ \"5XX\": {} }", "{ \"599\": {} }",
  ]
  // The main Stub comes last.
  let mains = cases.map(responses => {
    let stubs = main_of(responses)
    stubs
    .split("\n")
    .filter(line => line.has_prefix("petstore.r."))
    .collect()
    .last()
    .unwrap_or("")
  })
  inspect(
    mains.join("\n"),
    content=(
      #|petstore.r.200: GET /r -> 200
      #|petstore.r.2XX: GET /r -> 200
      #|petstore.r.default: GET /r -> 200
      #|petstore.r.302: GET /r -> 302
      #|petstore.r.3XX: GET /r -> 300
      #|petstore.r.4XX: GET /r -> 400
      #|petstore.r.5XX: GET /r -> 500
      #|petstore.r.599: GET /r -> 599
    ),
  )
}

///|
test "a response's headers are read where the document writes them, so their warnings come in that order among the warnings about its content" {
  inspect(
    main_of(
      (
        #|{
        #|  "404": { "description": "Not found", "content": { "application/json": {} } },
        #|  "200": {
        #|    "description": "OK",
        #|    "headers": {
        #|      "X-Rate-Limit": { "example": {} },
        #|      "content-type": {}, "Content-Length": {}, "Transfer-Encoding": {}, "Connection": {}
        #|    },
        #|    "content": { "application/json": {}, "application/xml": {} },
        #|    "links": { "next": {} }
        #|  },
        #|  "default": { "description": "Error", "headers": { "Retry-After": { "example": null } } },
        #|  "1XX": {},
        #|  "x-codes": { "anything": true }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Rate-Limit/example: warning: left out: a header cannot hold an object
      #|petstore.json: /paths/~1r/get/responses/200/content/application~1xml: warning: left out: a response answers with one media type, here "application/json"
      #|petstore.json: /paths/~1r/get/responses/default/headers/Retry-After/example: warning: left out: a header cannot hold null
      #|petstore.json: /paths/~1r/get/responses/1XX: warning: left out: smock answers with a status from 200 to 599
      #|petstore.r.404: GET /r -> 404
      #|petstore.r.default: GET /r -> 500
      #|petstore.r.200: GET /r -> 200
      #|
    ),
  )
}

///|
test "a response key that is not a code from 100 to 599, an upper-case range from 1XX to 5XX, default or an x- extension is left out with a warning" {
  inspect(
    main_of(
      (
        #|{ "2xx": {}, "600": {}, "099": {}, "20": {}, "6XX": {}, "Default": {}, "OK": {}, "201": {} }
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/2xx: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/600: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/099: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/20: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/6XX: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/Default: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1r/get/responses/OK: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.r.201: GET /r -> 201
      #|
    ),
  )
}

///|
test "an operation without responses, or with an empty one, answers 200 with an empty body, with a warning, and its Stub ID ends in .200" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": { "get": { "operationId": "none" } },
          #|  "/b": { "get": { "operationId": "empty", "responses": {} } },
          #|  "/c": { "get": { "operationId": "extensions", "responses": { "x-note": "none" } } },
          #|  "/d": { "get": { "operationId": "malformed", "responses": { "OK": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/get: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.json: /paths/~1b/get/responses: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.json: /paths/~1c/get/responses: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.json: /paths/~1d/get/responses/OK: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1d/get/responses: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.none.200: GET /a -> 200
      #|petstore.empty.200: GET /b -> 200
      #|petstore.extensions.200: GET /c -> 200
      #|petstore.malformed.200: GET /d -> 200
      #|
    ),
  )
}

///|
test "an operation with only 1xx responses is left out, with a warning, and takes no part in the checks of IDs and conditions" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": {
          #|    "get": { "operationId": "upgrade", "responses": { "101": {}, "1XX": {} } },
          #|    "put": { "operationId": "upgrade", "responses": { "200": {} } }
          #|  },
          #|  "/b": { "get": { "operationId": "early", "responses": { "103": {} } } },
          #|  "/%62": { "get": { "responses": { "200": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/get/responses: warning: left out: the operation has only 1xx responses, and smock answers with a status from 200 to 599
      #|petstore.json: /paths/~1b/get/responses: warning: left out: the operation has only 1xx responses, and smock answers with a status from 200 to 599
      #|petstore.upgrade.200: PUT /a -> 200
      #|petstore.GET /%62.200: GET /b -> 200
      #|
    ),
  )
}

///|
test "a Stub ID is <mock>.<operationId>.<key>, or <mock>.<METHOD> <path>.<key> with the path as written when there is no operationId" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/pets": { "get": { "operationId": "listPets", "responses": { "2XX": {} } } },
          #|  "/caf%C3%A9": { "post": { "responses": { "default": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.listPets.2XX: GET /pets -> 200
      #|petstore.POST /caf%C3%A9.default: POST /café -> 200
      #|
    ),
  )
}

///|
test "a duplicate operationId among the imported operations, or a generated ID that repeats, is an error that names both places" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": {
          #|    "get": { "operationId": "getA", "responses": { "200": {} } },
          #|    "put": { "operationId": "getA", "responses": { "201": {} } }
          #|  },
          #|  "/b": {
          #|    "get": { "operationId": "GET /c", "responses": { "200": {} } },
          #|    "delete": { "operationId": "getA", "responses": { "204": {} } }
          #|  },
          #|  "/c": { "get": { "responses": { "200": {} } } }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/put/operationId: the operationId "getA" is already used at petstore.json: /paths/~1a/get/operationId
      #|petstore.json: /paths/~1b/delete/operationId: the operationId "getA" is already used at petstore.json: /paths/~1a/get/operationId
      #|petstore.json: /paths/~1c/get: the Stub ID "petstore.GET /c.200" is already generated for the operation at petstore.json: /paths/~1b/get
      #|nothing written
      #|
    ),
  )
}

///|
test "operations that are not imported take no part in the check of IDs" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a/b": { "get": { "operationId": "getA", "responses": { "101": {} } } },
          #|  "/a": {
          #|    "get": {
          #|      "operationId": "getA",
          #|      "responses": { "200": {} },
          #|      "callbacks": { "onEvent": { "{$request.body#/url}": { "post": { "operationId": "getA" } } } }
          #|    }
          #|  }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a~1b/get/responses: warning: left out: the operation has only 1xx responses, and smock answers with a status from 200 to 599
      #|petstore.json: /paths/~1a/get/callbacks: warning: callbacks are not imported
      #|petstore.getA.200: GET /a -> 200
      #|
    ),
  )
}

///|
test "callbacks and webhooks get one warning each; security, links, descriptions, tags and x- extensions add nothing and get none; deprecated operations are imported like any other" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "info": { "title": "T", "version": "1", "description": "D" },
        #|  "tags": [{ "name": "pets" }],
        #|  "security": [{ "key": [] }],
        #|  "x-vendor": { "anything": true },
        #|  "webhooks": { "newPet": { "post": { "responses": { "200": {} } } } },
        #|  "components": { "securitySchemes": { "key": { "type": "apiKey", "in": "header", "name": "K" } } },
        #|  "paths": {
        #|    "/pets": {
        #|      "description": "Pets",
        #|      "x-path-note": 1,
        #|      "post": {
        #|        "operationId": "addPet",
        #|        "summary": "Add a pet",
        #|        "tags": ["pets"],
        #|        "deprecated": true,
        #|        "security": [{ "key": [] }],
        #|        "parameters": [{ "name": "q", "in": "query", "required": true }],
        #|        "requestBody": { "content": { "application/json": {} } },
        #|        "callbacks": { "onAdded": {} },
        #|        "x-codegen": "skip",
        #|        "responses": { "201": { "description": "Added", "links": { "pet": {} }, "x-note": 1 } }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|petstore.json: /paths/~1pets/post/callbacks: warning: callbacks are not imported
      #|petstore.addPet.201: POST /pets -> 201
      #|
    ),
  )
}

///|
test "a document with no operation to import gives a file without Stubs, with a warning among the document-level ones" {
  inspect(
    import_json(
      (
        #|{ "openapi": "3.1.0", "info": { "title": "T", "version": "1" } }
      ),
    ),
    content=(
      #|petstore.json: warning: there is no operation to import: the file has no Stubs
      #|0 Stubs from 0 operations
      #|{
      #|  "version": 1,
      #|  "mocks": [
      #|    {
      #|      "name": "petstore"
      #|    }
      #|  ],
      #|  "stubs": []
      #|}
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "webhooks": { "w": {} },
        #|  "paths": { "/a/{id}": { "get": { "responses": { "101": {} } } }, "/b": {} }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|petstore.json: /paths: warning: there is no operation to import: the file has no Stubs
      #|petstore.json: /paths/~1a~1{id}/get/responses: warning: left out: the operation has only 1xx responses, and smock answers with a status from 200 to 599
      #|
    ),
  )
}

///|
test "a field the converter reads that has the wrong JSON type is an error at its pointer; parts it does not read are not checked" {
  inspect(
    stubs_of(
      with_paths(
        (
          #|{
          #|  "/a": [],
          #|  "/b": {
          #|    "get": "list",
          #|    "put": { "operationId": "", "responses": { "200": {} } },
          #|    "post": { "operationId": 7, "responses": [] },
          #|    "patch": {
          #|      "responses": { "200": [], "404": "Not found" },
          #|      "requestBody": { "content": { "application/json": { "schema": { "$ref": "#/nowhere" } } } },
          #|      "parameters": "broken"
          #|    },
          #|    "delete": { "responses": { "200": { "content": [], "headers": "none" } } }
          #|  }
          #|}
        ),
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a: must be an object
      #|petstore.json: /paths/~1b/get: must be an object
      #|petstore.json: /paths/~1b/put/operationId: must be a non-empty string
      #|petstore.json: /paths/~1b/post/operationId: must be a non-empty string
      #|petstore.json: /paths/~1b/post/responses: must be an object
      #|petstore.json: /paths/~1b/patch/responses/200: must be an object
      #|petstore.json: /paths/~1b/patch/responses/404: must be an object
      #|petstore.json: /paths/~1b/delete/responses/200/content: must be an object
      #|petstore.json: /paths/~1b/delete/responses/200/headers: must be an object
      #|nothing written
      #|
    ),
  )
  inspect(
    stubs_of("{ \"openapi\": \"3.0.3\", \"paths\": [] }"),
    content=(
      #|petstore.json: /paths: must be an object
      #|nothing written
      #|
    ),
  )
}

///|
test "problems come in order: the document-level ones, then each operation's in the order the document writes them, and within an operation in the order of its responses" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "paths": {
        #|    "/b": {
        #|      "get": {
        #|        "responses": {
        #|          "404": { "content": { "application/json": {}, "text/xml": {} } },
        #|          "200": { "content": { "text/plain": { "example": "OK" } } },
        #|          "500": { "headers": { "X-Error": { "example": null } } }
        #|        }
        #|      },
        #|      "put": { "operationId": 1, "servers": [{ "url": "/{v}" }] }
        #|    },
        #|    "/a/{id}": { "get": {} }
        #|  },
        #|  "webhooks": { "w": {} },
        #|  "servers": [{ "url": "/v1" }, { "url": "/v2" }],
        #|  "openapi": "3.1.0"
        #|}
      ),
    ),
    content=(
      #|petstore.json: /servers: warning: left out: the servers have different paths, so only the first is used: "/v1" puts "/v1" in front of the paths
      #|petstore.json: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|petstore.json: /paths/~1b/get/responses/404/content/text~1xml: warning: left out: a response answers with one media type, here "application/json"
      #|petstore.json: /paths/~1b/get/responses/500/headers/X-Error/example: warning: left out: a header cannot hold null
      #|petstore.json: /paths/~1b/put/servers/0/url: the variable {v} has no default: declare it under "variables", with a "default"
      #|petstore.json: /paths/~1b/put/operationId: must be a non-empty string
      #|petstore.json: /paths/~1b/put: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.json: /paths/~1a~1{id}/get: warning: has no responses: the operation answers 200 with an empty body
      #|nothing written
      #|
    ),
  )
}

///|
test "the Mock is named by the option, which starts every Stub ID, and the file declares it with no other field" {
  inspect(
    import_json(
      with_paths("{ \"/a\": { \"get\": { \"responses\": { \"204\": {} } } } }"),
      mock="pet store",
    ),
    content=(
      #|1 Stubs from 1 operations
      #|{
      #|  "version": 1,
      #|  "mocks": [
      #|    {
      #|      "name": "pet store"
      #|    }
      #|  ],
      #|  "stubs": [
      #|    {
      #|      "id": "pet store.GET /a.204",
      #|      "mock": "pet store",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/a"
      #|      },
      #|      "response": {
      #|        "status": 204
      #|      }
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
}

///|
test "the same documents and options give the same bytes: UTF-8, LF line ends and a final newline" {
  let document = @utf8.encode(
    with_paths(
      (
        #|{
        #|  "/b": { "get": { "operationId": "b", "responses": { "200": {} } } },
        #|  "/caf%C3%A9\r\n": { "post": { "responses": { "201": {} } } }
        #|}
      ),
    ),
  )
  let options = @importopenapi.Options(
    root="api.json",
    mock="m",
    output="m.json",
  )
  guard @importopenapi.convert([("api.json", document)], options)
    is Converted(file=first, ..) else {
    fail("not converted")
  }
  guard @importopenapi.convert([("api.json", document)], options)
    is Converted(file=second, ..) else {
    fail("not converted")
  }
  assert_eq(first, second)
  let text = @utf8.decode(first)
  assert_true(text.has_suffix("}\n"))
  assert_false(text.contains_char('\r'))
  inspect(
    text,
    content=(
      #|{
      #|  "version": 1,
      #|  "mocks": [
      #|    {
      #|      "name": "m"
      #|    }
      #|  ],
      #|  "stubs": [
      #|    {
      #|      "id": "m.b.200",
      #|      "mock": "m",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/b"
      #|      },
      #|      "response": {
      #|        "status": 200
      #|      }
      #|    },
      #|    {
      #|      "id": "m.POST /caf%C3%A9\r\n.201",
      #|      "mock": "m",
      #|      "request": {
      #|        "method": "POST",
      #|        "path": "/café\r\n"
      #|      },
      #|      "response": {
      #|        "status": 201
      #|      }
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
}
