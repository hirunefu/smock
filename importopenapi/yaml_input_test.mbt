// YAML documents: a root document whose name ends in .yaml or .yml is read
// as YAML 1.2, as OpenAPI recommends, with smock/yaml's mode for OpenAPI
// documents. Definition files keep the safe subset.

///|
/// Converts `document`, a YAML OpenAPI document named `name`, into the
/// Definition file `output` for the Mock `petstore`, and renders what came
/// out, as `import_json` does.
fn import_yaml(
  document : String,
  name? : String = "petstore.yaml",
  output? : String = "defs/petstore.json",
) -> String {
  let options = @importopenapi.Options(root=name, mock="petstore", output~)
  rendered(@importopenapi.convert([(name, @utf8.encode(document))], options))
}

///|
test "a YAML document is read as YAML 1.2: an unquoted status key such as 200: is the key \"200\"" {
  inspect(
    import_yaml(
      (
        #|openapi: 3.1.0
        #|info:
        #|  title: Petstore
        #|  version: 1.0.0
        #|paths:
        #|  /pets:
        #|    get:
        #|      operationId: listPets
        #|      responses:
        #|        200:
        #|          description: A list of pets
        #|        404:
        #|          description: Not found
      ),
    ),
    content=(
      #|2 Stubs from 1 operations
      #|{
      #|  "version": 1,
      #|  "mocks": [
      #|    {
      #|      "name": "petstore"
      #|    }
      #|  ],
      #|  "stubs": [
      #|    {
      #|      "id": "petstore.listPets.404",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/pets",
      #|        "headers": {
      #|          "Smock-Status": "404"
      #|        }
      #|      },
      #|      "response": {
      #|        "status": 404
      #|      }
      #|    },
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
test "plain values are typed by the YAML 1.2 core schema: dates, yes and 1_000 are strings, 007 and 0x1F are numbers, True is a boolean, and ~ and an empty value are null" {
  inspect(
    import_yaml(
      (
        #|openapi: 3.1.0
        #|paths:
        #|  /pets:
        #|    get:
        #|      responses:
        #|        200:
        #|          description:
        #|          content:
        #|            application/json:
        #|              schema:
        #|                type: object
        #|                properties:
        #|                  born: { type: string, example: 2020-01-01 }
        #|                  legacy: { example: yes }
        #|                  count: { example: 1_000 }
        #|                  code: { example: 007 }
        #|                  mask: { example: 0x1F }
        #|                  mode: { example: 0o17 }
        #|                  delta: { example: +1 }
        #|                  ratio: { example: .5 }
        #|                  enabled: { example: True }
        #|                  tag: { example: ~ }
        #|                  nickname:
        #|                    example:
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
      #|      "id": "petstore.GET /pets.200",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/pets"
      #|      },
      #|      "response": {
      #|        "status": 200,
      #|        "json": {
      #|          "born": "2020-01-01",
      #|          "legacy": "yes",
      #|          "count": "1_000",
      #|          "code": 7,
      #|          "mask": 31,
      #|          "mode": 15,
      #|          "delta": 1,
      #|          "ratio": 0.5,
      #|          "enabled": true,
      #|          "tag": null,
      #|          "nickname": null
      #|        }
      #|      }
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
}

///|
test "a block scalar may have an indentation indicator, as YAML writers emit for text that starts with spaces" {
  inspect(
    import_yaml(
      (
        #|openapi: 3.1.0
        #|paths:
        #|  /readme:
        #|    get:
        #|      responses:
        #|        200:
        #|          content:
        #|            text/plain:
        #|              schema:
        #|                example: |2
        #|                    indented code
        #|                  text
        #|                type: string
      ),
      name="petstore.yml",
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
      #|      "id": "petstore.GET /readme.200",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/readme"
      #|      },
      #|      "response": {
      #|        "status": 200,
      #|        "headers": {
      #|          "Content-Type": "text/plain"
      #|        },
      #|        "body": "  indented code\ntext\n"
      #|      }
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
}

///|
test "an unquoted openapi: 3.1 is a number, and gets the error that says to quote it and give the patch; an unquoted 3.1.0 is the string \"3.1.0\"" {
  let versions = [
    "openapi: 3.1", "openapi: 3.0", "openapi: 3", "openapi: 3.1.0", "openapi: \"3.1.0\"",
    "openapi: 3.1.0\ninfo: { title: Petstore, version: 1.0 }",
  ].map(version => {
    first_line(
      import_yaml(
        "\{version}\npaths: { /pets: { get: { responses: { 200: {} } } } }",
      ),
    )
  })
  inspect(
    versions.join("\n"),
    content=(
      #|petstore.yaml: /openapi: must be a string such as "3.1.0": quote the version, and give its patch
      #|petstore.yaml: /openapi: must be a string such as "3.1.0": quote the version, and give its patch
      #|petstore.yaml: /openapi: must be a string such as "3.1.0": quote the version, and give its patch
      #|1 Stubs from 1 operations
      #|1 Stubs from 1 operations
      #|petstore.yaml: /info/version: must be a string: quote the version
    ),
  )
}

///|
/// What converting a YAML document gives when the `responses` of its
/// operation `GET /pets` are written as the lines `responses`, indented by
/// eight spaces: its first problem, or the number of Stubs.
fn with_yaml_responses(responses : String) -> String {
  let document =
    #|openapi: 3.1.0
    #|paths:
    #|  /pets:
    #|    get:
    #|      responses:
    #|
  let rendering = import_yaml(document + responses + "\n")
  rendering
  .split("\n")
  .filter(line => line != "nothing written")
  .next()
  .unwrap_or("")
  .to_owned()
}

///|
test "each YAML problem is an error at its JSON Pointer, with smock/yaml's message, and nothing is written; an alias suggests $ref" {
  let cases = [
    // an anchor
    (
      #|        200: &ok { description: OK }
      #|        404: { description: Gone }
    ),
    // an alias
    (
      #|        200: { description: OK }
      #|        404: *ok
    ),
    // a tag
    (
      #|        200: { description: !!str OK }
    ),
    // a merge key
    (
      #|        200:
      #|          <<: { description: OK }
    ),
    // a repeated key: 200 and "200" are the same string
    (
      #|        200: { description: OK }
      #|        "200": { description: Also OK }
    ),
    // several documents
    (
      #|        200: { description: OK }
      #|---
      #|openapi: 3.1.0
    ),
    // an explicit key
    (
      #|        ? 200
      #|        : { description: OK }
    ),
    // a hexadecimal integer above 2^53 - 1
    (
      #|        200: { content: { application/json: { schema: { example: 0x20000000000000 } } } }
    ),
    // infinity
    (
      #|        200: { content: { application/json: { schema: { example: .inf } } } }
    ),
    // NaN
    (
      #|        200: { content: { application/json: { schema: { example: .NaN } } } }
    ),
    // half of a surrogate pair, which UTF-8 cannot hold
    (
      #|        200: { description: "\ud800" }
    ),
    // the other half, and the first half written with \U
    (
      #|        200: { description: "\udc00 \U0000D800" }
    ),
    // a tab in indentation
    (
      #|        200:
      #|	  description: OK
    ),
    // a syntax error
    (
      #|        200: { description: OK
    ),
  ]
  inspect(
    cases.map(with_yaml_responses).join("\n"),
    content=(
      #|petstore.yaml: /paths/~1pets/get/responses/200: anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
      #|petstore.yaml: /paths/~1pets/get/responses/404: aliases (*) are not supported; reuse parts with $ref, or quote the value if it is text
      #|petstore.yaml: /paths/~1pets/get/responses/200/description: tags (!) are not supported; quote the value if it is text
      #|petstore.yaml: /paths/~1pets/get/responses/200/<<: merge keys (<<) are not supported
      #|petstore.yaml: /paths/~1pets/get/responses/200: duplicate key
      #|petstore.yaml: multiple documents are not supported
      #|petstore.yaml: /paths/~1pets/get/responses: explicit keys (?) are not supported
      #|petstore.yaml: /paths/~1pets/get/responses/200/content/application~1json/schema/example: "0x20000000000000" is above 2^53 - 1; write it in decimal, or quote this value
      #|petstore.yaml: /paths/~1pets/get/responses/200/content/application~1json/schema/example: ".inf" is infinity, which JSON cannot hold; quote this value
      #|petstore.yaml: /paths/~1pets/get/responses/200/content/application~1json/schema/example: ".NaN" is NaN, which JSON cannot hold; quote this value
      #|petstore.yaml: /paths/~1pets/get/responses/200/description: invalid escape: a high surrogate must be followed by a low surrogate
      #|petstore.yaml: /paths/~1pets/get/responses/200/description: invalid escape: not a Unicode character
      #|petstore.yaml: /paths/~1pets/get/responses/200: tabs are not allowed in indentation
      #|petstore.yaml: /paths/~1pets/get/responses/200/description: unterminated flow mapping
    ),
  )
}

///|
test "a YAML document must be UTF-8, one document without directives, and a mapping; a leading byte order mark is skipped" {
  let document = b"openapi: 3.1.0\npaths: { /pets: { get: { responses: { 200: {} } } } }\n"
  let inputs : Array[Bytes] = [
    b"\xef\xbb\xbf" + document,
    b"openapi: 3.1.0\ninfo: { title: \"\xff\" }\n",
    b"%YAML 1.2\n---\n" + document,
    b"",
    b"# only a comment\n",
    b"- openapi: 3.1.0\n",
    b"openapi 3.1.0\n",
  ]
  let options = @importopenapi.Options(
    root="api.yaml",
    root_label="docs/api.yaml",
    mock="m",
    output="m.json",
  )
  let rendered = inputs.map(bytes => {
    first_line(rendered(@importopenapi.convert([("api.yaml", bytes)], options)))
  })
  inspect(
    rendered.join("\n"),
    content=(
      #|1 Stubs from 1 operations
      #|docs/api.yaml: not valid UTF-8
      #|docs/api.yaml: directives (%) are not supported
      #|docs/api.yaml: the document is empty
      #|docs/api.yaml: the document is empty
      #|docs/api.yaml: must be an object
      #|docs/api.yaml: must be an object
    ),
  )
}

///|
test "a YAML document imports into a YAML Definition file in the safe subset: the values YAML 1.2 reads as strings are quoted there" {
  inspect(
    import_yaml(
      (
        #|openapi: 3.1.0
        #|info:
        #|  title: Petstore
        #|  version: 2020-01-01
        #|paths:
        #|  /pets:
        #|    get:
        #|      operationId: listPets
        #|      summary: List pets born on 2020-01-01
        #|      responses:
        #|        200:
        #|          content:
        #|            application/json:
        #|              schema:
        #|                type: object
        #|                properties:
        #|                  born: { example: 2020-01-01 }
        #|                  legacy: { example: yes }
        #|                  code: { example: 007 }
        #|                  tag: { example: ~ }
      ),
      output="defs/petstore.yaml",
    ),
    content=(
      #|1 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.yaml
      #|# (Petstore 2020-01-01, OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets, 200: List pets born on 2020-01-01
      #|  - id: petstore.listPets.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /pets
      #|    response:
      #|      status: 200
      #|      json:
      #|        born: "2020-01-01"
      #|        legacy: "yes"
      #|        code: 7
      #|        tag: null
      #|
    ),
  )
}

///|
test "the extension of the root document's name picks the parser: .yaml and .yml read YAML, .json reads JSON, and any other name is an error" {
  let yaml = "openapi: 3.1.0\npaths: { /pets: { get: { responses: { 200: {} } } } }\n"
  let rendered = ["api.yaml", "api.yml", "api.json", "api.YAML", "api.txt"].map(name => {
      let options = @importopenapi.Options(root=name, mock="m", output="m.json")
      let conversion = @importopenapi.convert(
        [(name, @utf8.encode(yaml))],
        options,
      )
      "\{name}: \{first_line(rendered(conversion))}"
    },
  )
  inspect(
    rendered.join("\n"),
    content=(
      #|api.yaml: 1 Stubs from 1 operations
      #|api.yml: 1 Stubs from 1 operations
      #|api.json: api.json: not valid JSON: Invalid character 'o' at line 1, column 0
      #|api.YAML: api.YAML: an OpenAPI document's name ends in .json, .yaml or .yml
      #|api.txt: api.txt: an OpenAPI document's name ends in .json, .yaml or .yml
    ),
  )
}
