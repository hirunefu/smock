///|
/// Converts a document of the OpenAPI version `openapi` whose only
/// operation is `<meth> /r`, with the Responses Object `responses`, given as
/// JSON text, and renders its problems, one per line, then the `response`
/// of each Stub as the YAML file writes it, or `nothing written`.
fn responses_of(
  responses : String,
  openapi~ : String = "3.1.0",
  meth~ : String = "get",
) -> String raise {
  let document = "{ \"openapi\": \"\{openapi}\", \"paths\": { \"/r\": { \"\{meth}\": { \"operationId\": \"r\", \"responses\": \{responses} } } } }"
  let conversion = @importopenapi.convert(
    [("petstore.json", @utf8.encode(document))],
    @importopenapi.Options(
      root="petstore.json",
      mock="petstore",
      output="defs/petstore.json",
    ),
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
    guard stub is Object({ "response": response, .. }) else {
      fail("unexpected Stub: \{stub.stringify()}")
    }
    out.write_string(@utf8.decode_lossy(@yaml.write({ "response": response })))
  }
  out.to_string()
}

///|
test "a response's body is one fixed sample of its media type's schema, written in the file" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "description": "A pet",
        #|    "content": {
        #|      "application/json": {
        #|        "schema": {
        #|          "type": "object",
        #|          "properties": {
        #|            "id": { "type": "string", "format": "uuid" },
        #|            "born": { "type": "string", "format": "date" },
        #|            "tags": { "type": "array", "items": { "type": "string" } },
        #|            "password": { "type": "string", "writeOnly": true }
        #|          }
        #|        }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 200
      #|  json:
      #|    id: 00000000-0000-4000-8000-000000000000
      #|    born: "2000-01-01"
      #|    tags:
      #|      - string
      #|
    ),
  )
}

///|
test "a response answers with one media type: application/json, with any parameters, else the first +json type, else the first key, compared case-insensitively without parameters; the others are left out with a warning" {
  inspect(
    responses_of(
      (
        #|{
        #|  "201": {
        #|    "content": {
        #|      "text/plain": { "schema": { "type": "string" } },
        #|      "Application/JSON ; charset=utf-8": { "schema": { "type": "boolean" } },
        #|      "application/json": { "schema": { "type": "string" } }
        #|    }
        #|  },
        #|  "202": {
        #|    "content": {
        #|      "text/plain": { "schema": { "type": "string" } },
        #|      "application/problem+JSON": { "schema": { "type": "boolean" } },
        #|      "application/hal+json": { "schema": { "type": "string" } }
        #|    }
        #|  },
        #|  "203": {
        #|    "content": {
        #|      "text/csv": { "schema": { "type": "string" } },
        #|      "application/xml": { "schema": { "type": "boolean" } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/201/content/text~1plain: warning: left out: a response answers with one media type, here "Application/JSON ; charset=utf-8"
      #|petstore.json: /paths/~1r/get/responses/201/content/application~1json: warning: left out: a response answers with one media type, here "Application/JSON ; charset=utf-8"
      #|petstore.json: /paths/~1r/get/responses/202/content/text~1plain: warning: left out: a response answers with one media type, here "application/problem+JSON"
      #|petstore.json: /paths/~1r/get/responses/202/content/application~1hal+json: warning: left out: a response answers with one media type, here "application/problem+JSON"
      #|petstore.json: /paths/~1r/get/responses/203/content/application~1xml: warning: left out: a response answers with one media type, here "text/csv"
      #|response:
      #|  status: 202
      #|  headers:
      #|    Content-Type: application/problem+JSON
      #|  json: true
      #|response:
      #|  status: 203
      #|  headers:
      #|    Content-Type: text/csv
      #|  body: string
      #|response:
      #|  status: 201
      #|  headers:
      #|    Content-Type: Application/JSON ; charset=utf-8
      #|  json: true
      #|
    ),
  )
}

///|
test "the Content-Type is written in headers with the key as written, except for plain application/json with a json body, which smock sends with it, and for a range; status comes first, then headers, then json or body" {
  inspect(
    responses_of(
      (
        #|{
        #|  "201": { "content": { "application/json": { "schema": { "type": "string" } } } },
        #|  "202": { "content": { "APPLICATION/JSON": { "schema": { "type": "string" } } } },
        #|  "203": { "content": { "application/json;charset=utf-8": { "schema": { "type": "string" } } } },
        #|  "204": {},
        #|  "206": { "content": { "application/vnd.api+json": { "schema": { "type": "string" } } } },
        #|  "207": { "content": { "text/plain; charset=utf-8": { "schema": { "type": "string" } } } },
        #|  "208": { "content": { "*/*": { "schema": { "type": "object" } } } },
        #|  "209": { "content": { "application/*": { "schema": { "type": "string" } } } },
        #|  "210": { "content": { "*/*+json": { "schema": { "type": "string" } } } }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 202
      #|  json: string
      #|response:
      #|  status: 203
      #|  headers:
      #|    Content-Type: application/json;charset=utf-8
      #|  json: string
      #|response:
      #|  status: 204
      #|response:
      #|  status: 206
      #|  headers:
      #|    Content-Type: application/vnd.api+json
      #|  json: string
      #|response:
      #|  status: 207
      #|  headers:
      #|    Content-Type: text/plain; charset=utf-8
      #|  body: string
      #|response:
      #|  status: 208
      #|  json: {}
      #|response:
      #|  status: 209
      #|  body: string
      #|response:
      #|  status: 210
      #|  json: string
      #|response:
      #|  status: 201
      #|  json: string
      #|
    ),
  )
}

///|
test "a JSON media type gives json; under a range, a value that is not a string gives json too; another media type gives body: a string as it is, a number or a boolean as smock writes it, and an object, an array or null an empty body, with a warning" {
  inspect(
    responses_of(
      (
        #|{
        #|  "201": { "content": { "application/problem+json": { "schema": { "const": [1, "a"] } } } },
        #|  "202": { "content": { "*/*": { "schema": { "const": 2.50 } } } },
        #|  "203": { "content": { "application/*": { "schema": { "const": null } } } },
        #|  "213": { "content": { "*/*": { "schema": { "const": "text" } } } },
        #|  "206": { "content": { "text/plain": { "schema": { "const": "a ${b} \"c\"" } } } },
        #|  "207": { "content": { "text/plain": { "schema": { "const": 12345678901234567890 } } } },
        #|  "208": { "content": { "text/plain": { "schema": { "type": "integer" } } } },
        #|  "209": { "content": { "text/csv": { "schema": { "type": "boolean" } } } },
        #|  "210": { "content": { "text/plain": { "schema": { "type": "object" } } } },
        #|  "211": { "content": { "text/plain": { "schema": { "type": "array" } } } },
        #|  "212": { "content": { "text/plain": { "schema": { "type": "null" } } } }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/210/content/text~1plain/schema: warning: left out: the body is empty, since a "text/plain" body cannot hold an object
      #|petstore.json: /paths/~1r/get/responses/211/content/text~1plain/schema: warning: left out: the body is empty, since a "text/plain" body cannot hold an array
      #|petstore.json: /paths/~1r/get/responses/212/content/text~1plain/schema: warning: left out: the body is empty, since a "text/plain" body cannot hold null
      #|response:
      #|  status: 202
      #|  json: 2.5
      #|response:
      #|  status: 203
      #|  json: null
      #|response:
      #|  status: 213
      #|  body: text
      #|response:
      #|  status: 206
      #|  headers:
      #|    Content-Type: text/plain
      #|  body: a ${b} "c"
      #|response:
      #|  status: 207
      #|  headers:
      #|    Content-Type: text/plain
      #|  body: "12345678901234567890"
      #|response:
      #|  status: 208
      #|  headers:
      #|    Content-Type: text/plain
      #|  body: "0"
      #|response:
      #|  status: 209
      #|  headers:
      #|    Content-Type: text/csv
      #|  body: "true"
      #|response:
      #|  status: 210
      #|  headers:
      #|    Content-Type: text/plain
      #|response:
      #|  status: 211
      #|  headers:
      #|    Content-Type: text/plain
      #|response:
      #|  status: 212
      #|  headers:
      #|    Content-Type: text/plain
      #|response:
      #|  status: 201
      #|  headers:
      #|    Content-Type: application/problem+json
      #|  json:
      #|    - 1
      #|    - a
      #|
    ),
  )
}

///|
test "a response without content, or with an empty one, has no body and no Content-Type; a media type with neither an example nor a schema has an empty body and its Content-Type, with no warning" {
  inspect(
    responses_of(
      (
        #|{
        #|  "201": { "description": "Created" },
        #|  "202": { "content": {} },
        #|  "203": { "content": { "application/json": {} } },
        #|  "206": { "content": { "text/plain": { "encoding": {} } } },
        #|  "207": { "content": { "*/*": {} } }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 202
      #|response:
      #|  status: 203
      #|  headers:
      #|    Content-Type: application/json
      #|response:
      #|  status: 206
      #|  headers:
      #|    Content-Type: text/plain
      #|response:
      #|  status: 207
      #|response:
      #|  status: 201
      #|
    ),
  )
}

///|
test "204, 205 and 304 responses, and responses to HEAD, get no body and no Content-Type; content that the document gives them is left out, with a warning" {
  inspect(
    responses_of(
      (
        #|{
        #|  "204": { "content": { "application/json": { "schema": { "type": "string" } } } },
        #|  "205": { "content": { "text/plain": { "schema": { "type": "string" } } } },
        #|  "304": { "content": { "application/json": {} } },
        #|  "200": { "content": {} }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/204/content: warning: left out: a 204 response has no body
      #|petstore.json: /paths/~1r/get/responses/205/content: warning: left out: a 205 response has no body
      #|petstore.json: /paths/~1r/get/responses/304/content: warning: left out: a 304 response has no body
      #|response:
      #|  status: 204
      #|response:
      #|  status: 205
      #|response:
      #|  status: 304
      #|response:
      #|  status: 200
      #|
    ),
  )
  inspect(
    responses_of(
      (
        #|{
        #|  "200": { "content": { "application/json": { "schema": { "type": "string" } } } },
        #|  "404": { "content": { "text/plain": { "schema": { "type": "string" } } } }
        #|}
      ),
      meth="head",
    ),
    content=(
      #|petstore.json: /paths/~1r/head/responses/200/content: warning: left out: a response to HEAD has no body
      #|petstore.json: /paths/~1r/head/responses/404/content: warning: left out: a response to HEAD has no body
      #|response:
      #|  status: 404
      #|response:
      #|  status: 200
      #|
    ),
  )
}

///|
test "a Media Type Object that is not an object, or a schema that is neither an object nor a boolean, is an error at its pointer; the other media types are not read" {
  inspect(
    responses_of(
      (
        #|{
        #|  "201": { "content": { "application/json": [] } },
        #|  "200": { "content": { "application/json": { "schema": "Pet" }, "text/plain": 1 } }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/201/content/application~1json: must be an object
      #|petstore.json: /paths/~1r/get/responses/200/content/application~1json/schema: must be a schema, an object or a boolean
      #|petstore.json: /paths/~1r/get/responses/200/content/text~1plain: warning: left out: a response answers with one media type, here "application/json"
      #|nothing written
      #|
    ),
  )
}

///|
test "a Media Type Object reached through a $ref, as 3.2 allows, is followed" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": { "content": { "text/plain": { "$ref": "#/paths/~1r/get/responses/x-media" } } },
        #|  "x-media": { "schema": { "type": "boolean" } }
        #|}
      ),
      openapi="3.2.0",
    ),
    content=(
      #|response:
      #|  status: 200
      #|  headers:
      #|    Content-Type: text/plain
      #|  body: "true"
      #|
    ),
  )
}

///|
test "a Content-Type that a header cannot hold is left out, with a warning" {
  inspect(
    responses_of(
      (
        #|{ "200": { "content": { "text/plain\u0007": { "schema": { "type": "string" } } } } }
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/content/text~1plain\u{7}: warning: left out: the Content-Type, since a header cannot hold a control character
      #|response:
      #|  status: 200
      #|  body: string
      #|
    ),
  )
}

///|
test "the output has no template, so ${ in a value and keys that start with $ are written as they are, in YAML as in JSON, and the file loads with no warning" {
  inspect(
    import_to(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/r": {
        #|      "get": {
        #|        "operationId": "r",
        #|        "responses": {
        #|          "200": {
        #|            "content": {
        #|              "application/json": {
        #|                "schema": {
        #|                  "type": "object",
        #|                  "properties": {
        #|                    "$each": { "const": "${items}" },
        #|                    "$$name": { "type": "string" },
        #|                    "query": { "default": { "$ref": "#/x", "$if": "${a}" } }
        #|                  }
        #|                }
        #|              }
        #|            }
        #|          },
        #|          "404": { "content": { "text/plain": { "schema": { "const": "${missing}" } } } }
        #|        }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|2 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.json
      #|# (OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /r, 404
      #|  - id: petstore.r.404
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /r
      #|      headers:
      #|        Smock-Status: "404"
      #|    response:
      #|      status: 404
      #|      headers:
      #|        Content-Type: text/plain
      #|      body: ${missing}
      #|  # GET /r, 200
      #|  - id: petstore.r.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /r
      #|    response:
      #|      status: 200
      #|      json:
      #|        $each: ${items}
      #|        $$name: string
      #|        query:
      #|          $ref: "#/x"
      #|          $if: ${a}
      #|
    ),
  )
}
