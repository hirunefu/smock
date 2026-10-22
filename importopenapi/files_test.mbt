// Documents split into several files: a reference names a part of another
// document by its path, relative to the document that names it, under the
// directory references are followed in (--ref-dir).

///|
/// Converts `documents`, given as (name, text) pairs, from the root
/// document `root`, into a JSON Definition file for the Mock `petstore`,
/// and renders what came out, as `import_json` does. Problems name the root
/// `root_label`, and the other documents under `ref_dir`.
fn import_files(
  documents : Array[(String, String)],
  root? : String = "openapi.yaml",
  root_label? : String = "api/openapi.yaml",
  ref_dir? : String = "api/",
) -> String {
  let options = @importopenapi.Options(
    root~,
    root_label~,
    ref_dir~,
    mock="petstore",
    output="defs/petstore.json",
  )
  let given = documents.map(document => (document.0, @utf8.encode(document.1)))
  rendered(@importopenapi.convert(given, options))
}

///|
test "a reference to another file is followed: its path is relative to the document that names it, and its fragment names a part of that file" {
  inspect(
    import_files([
      (
        "openapi.yaml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /pets:
          #|    $ref: paths/pets.yaml
        ),
      ),
      (
        "paths/pets.yaml",
        (
          #|get:
          #|  operationId: listPets
          #|  responses:
          #|    200:
          #|      $ref: "../responses/ok.json#/Ok"
        ),
      ),
      (
        "responses/ok.json",
        (
          #|{ "Ok": { "description": "OK", "content": { "application/json": { "example": { "name": "Rex" } } } } }
        ),
      ),
    ]),
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
      #|        "status": 200,
      #|        "json": {
      #|          "name": "Rex"
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
test "a problem in another document is reported where it is written, in that document, named by --ref-dir joined with its name under --ref-dir" {
  let documents = [
    (
      "openapi.yaml",
      (
        #|openapi: 3.1.0
        #|paths:
        #|  /pets:
        #|    $ref: paths/pets.yaml
      ),
    ),
    (
      "paths/pets.yaml",
      (
        #|get:
        #|  deprecated: "yes"
        #|  callbacks:
        #|    onEvent: {}
        #|  responses:
        #|    200:
        #|      $ref: "#/components/Ok"
        #|    404:
        #|      $ref: "../responses/errors.json#/NotFound"
      ),
    ),
    ("responses/errors.json", "{}"),
  ]
  inspect(
    import_files(documents),
    content=(
      #|api/paths/pets.yaml: /get/deprecated: must be true or false
      #|api/paths/pets.yaml: /get/callbacks: warning: callbacks are not imported
      #|api/paths/pets.yaml: /get/responses/200/$ref: the document has nothing at /components/Ok
      #|api/paths/pets.yaml: /get/responses/404/$ref: api/responses/errors.json has nothing at /NotFound
      #|nothing written
      #|
    ),
  )
  let first_lines = ["api", "api/", "", ".", "/srv/api"].map(ref_dir => {
    "\{ref_dir.escape()}: \{first_line(import_files(documents, ref_dir~))}"
  })
  inspect(
    first_lines.join("\n"),
    content=(
      #|"api": api/paths/pets.yaml: /get/deprecated: must be true or false
      #|"api/": api/paths/pets.yaml: /get/deprecated: must be true or false
      #|"": paths/pets.yaml: /get/deprecated: must be true or false
      #|".": ./paths/pets.yaml: /get/deprecated: must be true or false
      #|"/srv/api": /srv/api/paths/pets.yaml: /get/deprecated: must be true or false
    ),
  )
}

///|
/// Converts the root document `openapi.yaml` of `files`, given as (name,
/// text) pairs, in rounds, as the CLI does: each round gives the documents
/// the conversion asked for, from `files`, or says that one is missing.
/// Renders the names asked for in each round, then what the conversion
/// gave, as `import_json` does.
fn in_rounds(files : Array[(String, String)]) -> String {
  let options = @importopenapi.Options(
    root="openapi.yaml",
    root_label="api/openapi.yaml",
    ref_dir="api",
    mock="petstore",
    output="defs/petstore.json",
  )
  let files = Map::from_array(files)
  let converter = @importopenapi.Converter::new(options)
  converter.give(
    "openapi.yaml",
    @utf8.encode(files.get("openapi.yaml").unwrap()),
  )
  let out = StringBuilder()
  for round = 1; ; round = round + 1 {
    let conversion = converter.convert()
    guard conversion is Needs(names) else {
      out.write_string(rendered(conversion))
      break
    }
    out.write_string("round \{round} asks for \{names.join(", ")}\n")
    for name in names {
      match files.get(name) {
        Some(text) => converter.give(name, @utf8.encode(text))
        None => converter.give_unreadable(name, Missing)
      }
    }
  }
  out.to_string()
}

///|
test "the converter asks for the documents it needs, in rounds, each once however many references name it, until it has them all" {
  inspect(
    in_rounds([
      (
        "openapi.yaml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /pets:
          #|    $ref: paths/pets.yaml
          #|  /pets/mine:
          #|    $ref: ./paths/../paths/mine.yaml
          #|  /owners:
          #|    get:
          #|      operationId: listOwners
          #|      responses:
          #|        200:
          #|          $ref: responses/ok.yaml
        ),
      ),
      (
        "paths/pets.yaml",
        (
          #|get:
          #|  operationId: listPets
          #|  responses:
          #|    200:
          #|      $ref: ../responses/ok.yaml
          #|    404:
          #|      $ref: ../responses/errors.yaml#/NotFound
        ),
      ),
      (
        "paths/mine.yaml",
        (
          #|get:
          #|  operationId: getMyPet
          #|  responses:
          #|    200:
          #|      $ref: "../responses/ok.yaml#"
        ),
      ),
      (
        "responses/ok.yaml",
        (
          #|description: OK
        ),
      ),
      (
        "responses/errors.yaml",
        (
          #|NotFound:
          #|  $ref: problems/not-found.yaml
        ),
      ),
      (
        "responses/problems/not-found.yaml",
        (
          #|description: Not found
        ),
      ),
    ]),
    content=(
      #|round 1 asks for paths/pets.yaml, paths/mine.yaml, responses/ok.yaml
      #|round 2 asks for responses/errors.yaml
      #|round 3 asks for responses/problems/not-found.yaml
      #|4 Stubs from 3 operations
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
      #|    },
      #|    {
      #|      "id": "petstore.listOwners.200",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/owners"
      #|      },
      #|      "response": {
      #|        "status": 200
      #|      }
      #|    },
      #|    {
      #|      "id": "petstore.getMyPet.200",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/pets/mine"
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
test "a document that cannot be read is an error at every $ref that names it, and one that cannot be parsed is reported once, in it; both come with the document-level problems" {
  let options = @importopenapi.Options(
    root="openapi.yaml",
    root_label="api/openapi.yaml",
    ref_dir="api",
    mock="petstore",
    output="defs/petstore.json",
  )
  let converter = @importopenapi.Converter::new(options)
  converter.give(
    "openapi.yaml",
    @utf8.encode(
      (
        #|openapi: 3.1.0
        #|webhooks:
        #|  newPet: {}
        #|paths:
        #|  /a:
        #|    get:
        #|      deprecated: 1
        #|      responses:
        #|        200:
        #|          $ref: missing.yaml
        #|        404:
        #|          $ref: "missing.yaml#/NotFound"
        #|  /b:
        #|    $ref: dir.yaml
        #|  /c:
        #|    $ref: outside.yaml
        #|  /d:
        #|    $ref: locked.yaml
        #|  /e:
        #|    $ref: broken.json
        #|  /f:
        #|    $ref: "broken.json#/x"
      ),
    ),
  )
  converter.give_unreadable("missing.yaml", Missing)
  converter.give_unreadable("dir.yaml", NotRegularFile)
  converter.give_unreadable("outside.yaml", SymlinkOutside)
  converter.give_unreadable("locked.yaml", Other("permission denied"))
  converter.give("broken.json", b"{ \"a\": ")
  inspect(
    rendered(converter.convert()),
    content=(
      #|api/openapi.yaml: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|api/openapi.yaml: /paths/~1a/get/responses/200/$ref: api/missing.yaml cannot be read: no such file
      #|api/openapi.yaml: /paths/~1a/get/responses/404/$ref: api/missing.yaml cannot be read: no such file
      #|api/openapi.yaml: /paths/~1b/$ref: api/dir.yaml cannot be read: not a regular file
      #|api/openapi.yaml: /paths/~1c/$ref: api/outside.yaml cannot be read: a symlink leads it outside --ref-dir
      #|api/openapi.yaml: /paths/~1d/$ref: api/locked.yaml cannot be read: permission denied
      #|api/broken.json: not valid JSON: Unexpected end of file
      #|api/openapi.yaml: /paths/~1a/get/deprecated: must be true or false
      #|nothing written
      #|
    ),
  )
}

///|
test "the path of a reference is percent-decoded, must end in .json, .yaml or .yml, and must not climb above --ref-dir" {
  let documents = [
    (
      "v1/openapi.yaml",
      (
        #|openapi: 3.1.0
        #|paths:
        #|  /a:
        #|    $ref: "my%20paths/a.yaml"
        #|  /b:
        #|    $ref: "../shared/b.yaml"
        #|  /c:
        #|    $ref: "../../c.yaml"
        #|  /d:
        #|    $ref: "../shared/%2E%2E/%2E%2E/d.yaml"
        #|  /e:
        #|    $ref: "e.txt"
        #|  /f:
        #|    $ref: "f.YAML"
        #|  /g:
        #|    $ref: "%2Fetc/g.yaml"
        #|  /h:
        #|    $ref: "h%00.yaml"
      ),
    ),
    (
      "v1/my paths/a.yaml",
      (
        #|get:
        #|  operationId: a
        #|  responses:
        #|    200:
        #|      description: OK
      ),
    ),
    (
      "shared/b.yaml",
      (
        #|get:
        #|  operationId: b
        #|  responses:
        #|    200:
        #|      description: OK
      ),
    ),
  ]
  inspect(
    import_files(
      documents,
      root="v1/openapi.yaml",
      root_label="v1/openapi.yaml",
      ref_dir=".",
    ),
    content=(
      #|v1/openapi.yaml: /paths/~1c/$ref: the file is outside --ref-dir: smock follows references only to files under it, by default the root document's directory
      #|v1/openapi.yaml: /paths/~1d/$ref: the file is outside --ref-dir: smock follows references only to files under it, by default the root document's directory
      #|v1/openapi.yaml: /paths/~1e/$ref: a referenced file's name must end in .json, .yaml or .yml
      #|v1/openapi.yaml: /paths/~1f/$ref: a referenced file's name must end in .json, .yaml or .yml
      #|v1/openapi.yaml: /paths/~1g/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|v1/openapi.yaml: /paths/~1h/$ref: a referenced file's path must not hold a NUL character, %00
      #|nothing written
      #|
    ),
  )
}

///|
test "a reference in another document may lead back into the root document, and references that form a cycle across documents are an error at the $ref that closes it" {
  inspect(
    import_files([
      (
        "openapi.yaml",
        (
          #|openapi: 3.1.0
          #|paths:
          #|  /a:
          #|    $ref: a.yaml
          #|  /b:
          #|    get:
          #|      operationId: getB
          #|      responses:
          #|        200:
          #|          $ref: "b.yaml#/Ok"
          #|components:
          #|  responses:
          #|    Ok:
          #|      description: OK
        ),
      ),
      ("a.yaml", "$ref: \"b.yaml#/A\""),
      (
        "b.yaml",
        (
          #|A:
          #|  $ref: a.yaml
          #|Ok:
          #|  $ref: "openapi.yaml#/components/responses/Ok"
        ),
      ),
    ]),
    content=(
      #|api/b.yaml: /A/$ref: a cycle of references: this one leads back to api/a.yaml
      #|nothing written
      #|
    ),
  )
}

///|
/// A root document whose paths `/p0`, `/p1`, ... each refer to a document
/// of their own, `p0.yaml`, `p1.yaml`, ..., `count` of them.
fn referring_to(count : Int) -> String {
  let paths = StringBuilder()
  for i in 0..<count {
    paths.write_string("  /p\{i}:\n    $ref: p\{i}.yaml\n")
  }
  "openapi: 3.1.0\npaths:\n\{paths}"
}

///|
test "at most 1,000 documents are read, the root included: the converter does not ask for more, and says so" {
  let asked = match
    @importopenapi.convert(
      [("openapi.yaml", @utf8.encode(referring_to(999)))],
      @importopenapi.Options(root="openapi.yaml", mock="m", output="m.json"),
    ) {
    Needs(names) => "\{names.length()} documents, \{names[0]} to \{names[998]}"
    _ => "no request"
  }
  inspect(asked, content="999 documents, p0.yaml to p998.yaml")
  inspect(
    import_files([("openapi.yaml", referring_to(1000))]),
    content=(
      #|api/openapi.yaml: the documents it refers to pass 1,000, the most smock import-openapi reads, the root included: bundle the document into one file first, with another tool
      #|nothing written
      #|
    ),
  )
}

///|
test "at most 64 MiB are read in all, the root included: the document with which the bytes pass the bound is an error" {
  let root = with_paths(
    "{ \"/a\": { \"get\": { \"responses\": { \"200\": {} } } } }",
  )
  let root_bytes = @utf8.encode(root).length()
  let options = @importopenapi.Options(
    root="openapi.json",
    root_label="api/openapi.json",
    ref_dir="api",
    mock="m",
    output="m.json",
  )
  // A document that no reference names counts too. This one is not even
  // parsed, so the test stays fast.
  let at_bound = @importopenapi.convert(
    [
      ("openapi.json", @utf8.encode(root)),
      (
        "padding.txt",
        Bytes::make(@importopenapi.max_read_bytes - root_bytes, 0),
      ),
    ],
    options,
  )
  inspect(first_line(rendered(at_bound)), content="1 Stubs from 1 operations")
  inspect(
    rendered(
      @importopenapi.convert(
        [
          ("openapi.json", @utf8.encode(root)),
          (
            "padding.txt",
            Bytes::make(@importopenapi.max_read_bytes - root_bytes + 1, 0),
          ),
        ],
        options,
      ),
    ),
    content=(
      #|api/padding.txt: with it, the documents read pass 64 MiB, the most smock import-openapi reads in all, the root included
      #|nothing written
      #|
    ),
  )
  inspect(
    rendered(
      @importopenapi.convert(
        [("openapi.json", Bytes::make(@importopenapi.max_read_bytes + 1, 0))],
        options,
      ),
    ),
    content=(
      #|api/openapi.json: is larger than 64 MiB, the most smock import-openapi reads
      #|nothing written
      #|
    ),
  )
}

///|
/// The YAML file that converting `documents`, given as (name, text) pairs,
/// from the root `root` gives, or no bytes when it gives none. Problems
/// would name the root `root_label`, and the others under `ref_dir`.
fn yaml_converted(
  documents : Array[(String, String)],
  root~ : String,
  root_label~ : String,
  ref_dir~ : String,
) -> Bytes {
  let options = @importopenapi.Options(
    root~,
    root_label~,
    ref_dir~,
    mock="petstore",
    output="defs/petstore.yaml",
  )
  let given = documents.map(document => (document.0, @utf8.encode(document.1)))
  match @importopenapi.convert(given, options) {
    Converted(file~, ..) => file
    _ => b""
  }
}

///|
test "the bytes do not depend on --ref-dir, on the paths given, or on the names of referenced documents" {
  let response =
    #|description: OK
    #|content:
    #|  application/json:
    #|    example: { name: Rex }
  let here = yaml_converted(
    [
      (
        "openapi.yaml", "openapi: 3.1.0\npaths:\n  /pets:\n    get:\n      responses:\n        200:\n          $ref: responses/ok.yaml\n",
      ),
      ("responses/ok.yaml", response),
    ],
    root="openapi.yaml",
    root_label="openapi.yaml",
    ref_dir="",
  )
  let elsewhere = yaml_converted(
    [
      (
        "v1/openapi.yaml", "openapi: 3.1.0\npaths:\n  /pets:\n    get:\n      responses:\n        200:\n          $ref: \"../common/200%20ok.yaml\"\n",
      ),
      ("common/200 ok.yaml", response),
    ],
    root="v1/openapi.yaml",
    root_label="/srv/specs/v1/openapi.yaml",
    ref_dir="/srv/specs",
  )
  assert_eq(here, elsewhere)
  inspect(
    @utf8.decode_lossy(here),
    content=(
      #|# Generated by smock import-openapi from openapi.yaml
      #|# (OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets, 200
      #|  - id: petstore.GET /pets.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /pets
      #|    response:
      #|      status: 200
      #|      json:
      #|        name: Rex
      #|
    ),
  )
}

///|
test "a referenced document need not be an OpenAPI document: its openapi field is not checked, and the schema rules follow the root document's version" {
  let documents = [
    (
      "openapi.json",
      (
        #|{
        #|  "openapi": "3.0.3",
        #|  "paths": {
        #|    "/pets/mine": {
        #|      "get": {
        #|        "operationId": "getMyPet",
        #|        "responses": { "200": { "$ref": "responses.json#/Pet" } }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    (
      "responses.json",
      (
        #|{
        #|  "openapi": "4.0.0",
        #|  "Pet": {
        #|    "description": "My pet",
        #|    "content": {
        #|      "application/json": {
        #|        "schema": { "type": "string", "examples": ["Rex"] }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
  ]
  let bodies = ["3.0.3", "3.1.0"].map(version => {
    let documents = documents.copy()
    documents[0] = (
      "openapi.json",
      documents[0].1.replace(old="3.0.3", new=version),
    )
    let file = yaml_converted(
      documents,
      root="openapi.json",
      root_label="openapi.json",
      ref_dir="",
    )
    let body = @utf8.decode_lossy(file)
      .split("\n")
      .filter(line => line.has_prefix("      json:"))
      .map(line => line.trim(chars=" ").to_owned())
      .collect()
    "\{version}: \{body.join(", ")}"
  })
  inspect(
    bodies.join("\n"),
    content=(
      #|3.0.3: json: string
      #|3.1.0: json: Rex
    ),
  )
}

///|
test "a schema $ref into another file is followed from the file it is in, a schema that names itself there ends, and a $id inside that file is an error at it, while one at its root is ignored" {
  let root =
    #|openapi: 3.1.0
    #|paths:
    #|  /nodes:
    #|    get:
    #|      operationId: getNode
    #|      responses:
    #|        200:
    #|          description: OK
    #|          content:
    #|            application/json:
    #|              schema:
    #|                $ref: schemas/node.yaml#/Node
  let node =
    #|$id: https://example.com/schemas/node.yaml
    #|Node:
    #|  type: object
    #|  required: [name]
    #|  properties:
    #|    name:
    #|      $ref: common.yaml#/Name
    #|    children:
    #|      type: array
    #|      items:
    #|        $ref: "#/Node"
  let common =
    #|Name:
    #|  type: string
    #|  example: Rex
  inspect(
    import_files([
      ("openapi.yaml", root),
      ("schemas/node.yaml", node),
      ("schemas/common.yaml", common),
    ]),
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
      #|      "id": "petstore.getNode.200",
      #|      "mock": "petstore",
      #|      "request": {
      #|        "method": "GET",
      #|        "path": "/nodes"
      #|      },
      #|      "response": {
      #|        "status": 200,
      #|        "json": {
      #|          "name": "Rex",
      #|          "children": []
      #|        }
      #|      }
      #|    }
      #|  ]
      #|}
      #|
    ),
  )
  let pet =
    #|Pet:
    #|  $id: https://example.com/pet
    #|  type: object
    #|  properties:
    #|    owner:
    #|      $ref: common.yaml#/Name
  inspect(
    import_files([
      ("openapi.yaml", root.replace(old="node.yaml#/Node", new="pet.yaml#/Pet")),
      ("schemas/pet.yaml", pet),
      ("schemas/common.yaml", common),
    ]),
    content=(
      #|api/schemas/pet.yaml: /Pet/$id: a $ref lies under this $id, which would change what the $ref names: smock does not resolve $id
      #|nothing written
      #|
    ),
  )
}

///|
test "a file that cannot be read, which only the discarded first sample of a schema reached, is not reported, and the problems found before that sample stay" {
  inspect(
    in_rounds([
      (
        "openapi.yaml",
        (
          #|openapi: 3.1.0
          #|webhooks:
          #|  newPet: {}
          #|paths:
          #|  /a:
          #|    get:
          #|      operationId: getA
          #|      callbacks:
          #|        onEvent: {}
          #|      responses:
          #|        200:
          #|          description: OK
          #|          content:
          #|            application/json:
          #|              schema:
          #|                $ref: missing.yaml#/A
          #|  /b:
          #|    get:
          #|      operationId: getB
          #|      responses:
          #|        200:
          #|          description: OK
          #|          content:
          #|            application/json:
          #|              schema:
          #|                type: object
          #|                properties:
          #|                  pet:
          #|                    type: object
          #|                    properties:
          #|                      details:
          #|                        type: object
          #|                        properties:
          #|                          extra:
          #|                            $ref: missing.yaml#/B
          #|                          blob:
          #|                            type: string
          #|                            minLength: 70000
        ),
      ),
    ]),
    content=(
      #|round 1 asks for missing.yaml
      #|api/openapi.yaml: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|api/openapi.yaml: /paths/~1a/get/responses/200/content/application~1json/schema/$ref: api/missing.yaml cannot be read: no such file
      #|api/openapi.yaml: /paths/~1a/get/callbacks: warning: callbacks are not imported
      #|nothing written
      #|
    ),
  )
}
