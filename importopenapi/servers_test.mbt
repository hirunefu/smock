// Servers and base paths: the path of a server URL, or --base-path, is put
// in front of every path.

///|
test "the path of the document's server is put in front of every path" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "servers": [{ "url": "https://api.example.com/v1" }],
        #|  "paths": {
        #|    "/pets": { "get": { "operationId": "listPets", "responses": { "200": {} } } },
        #|    "/pets/{petId}": { "get": { "operationId": "getPetById", "responses": { "200": {} } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.listPets.200: GET /v1/pets -> 200
      #|petstore.getPetById.200: GET pattern /v1/pets/[^/]+ -> 200
      #|
    ),
  )
}

///|
test "the server is the first of the operation's servers, else of the Path Item's, else of the document's; an empty list is no list" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "servers": [{ "url": "/v1" }, { "url": "/v1/" }],
        #|  "paths": {
        #|    "/pets": {
        #|      "servers": [{ "url": "/v2" }],
        #|      "get": { "operationId": "listPets", "responses": { "200": {} } },
        #|      "put": {
        #|        "operationId": "replacePets",
        #|        "servers": [{ "url": "/v3" }, { "url": "/v3" }],
        #|        "responses": { "200": {} }
        #|      },
        #|      "post": { "operationId": "addPet", "servers": [], "responses": { "201": {} } }
        #|    },
        #|    "/toys": {
        #|      "servers": [],
        #|      "get": { "operationId": "listToys", "responses": { "200": {} } },
        #|      "put": { "operationId": "replaceToys", "servers": [{ "url": "/v3" }], "responses": { "200": {} } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.listPets.200: GET /v2/pets -> 200
      #|petstore.replacePets.200: PUT /v3/pets -> 200
      #|petstore.addPet.201: POST /v2/pets -> 201
      #|petstore.listToys.200: GET /v1/toys -> 200
      #|petstore.replaceToys.200: PUT /v3/toys -> 200
      #|
    ),
  )
}

///|
/// The method and path of the Stub of `GET /pets` under a document whose
/// `servers` are `servers`, given as JSON text, or the problems.
fn under_servers(servers : String) -> String raise {
  stubs_of(
    "{ \"openapi\": \"3.1.0\", \"servers\": \{servers}, \"paths\": { \"/pets\": { \"get\": { \"operationId\": \"listPets\", \"responses\": { \"200\": {} } } } } }",
  )
}

///|
/// The method and path of the Stub of `GET /pets` under a document whose
/// only server has the URL `url`, given as JSON text, or the problems.
fn under_server(url : String) -> String raise {
  under_servers("[{ \"url\": \{url} }]")
}

///|
test "the path of an absolute URL is taken, whatever its host, and a relative URL is resolved against /; one trailing / is dropped" {
  let urls = [
    "https://api.example.com/v1", "https://api.example.com/v1/", "https://api.example.com",
    "https://api.example.com/", "http://localhost:8080/api/v1", "HTTPS://user@[2001:db8::1]:8443/v1",
    "//cdn.example.com/v1", "/v1", "/v1/", "/v1//", "/", "", "v1", "./v1", "../v1",
    ".", "/a/./b/../c", "https://api.example.com/a/b/..",
  ]
  let lines = []
  for url in urls {
    lines.push("\{url.escape()} -> \{under_server(url.escape())}")
  }
  inspect(
    lines.join(""),
    content=(
      #|"https://api.example.com/v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"https://api.example.com/v1/" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"https://api.example.com" -> petstore.listPets.200: GET /pets -> 200
      #|"https://api.example.com/" -> petstore.listPets.200: GET /pets -> 200
      #|"http://localhost:8080/api/v1" -> petstore.listPets.200: GET /api/v1/pets -> 200
      #|"HTTPS://user@[2001:db8::1]:8443/v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"//cdn.example.com/v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"/v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"/v1/" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"/v1//" -> petstore.listPets.200: GET /v1//pets -> 200
      #|"/" -> petstore.listPets.200: GET /pets -> 200
      #|"" -> petstore.listPets.200: GET /pets -> 200
      #|"v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"./v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"../v1" -> petstore.listPets.200: GET /v1/pets -> 200
      #|"." -> petstore.listPets.200: GET /pets -> 200
      #|"/a/./b/../c" -> petstore.listPets.200: GET /a/c/pets -> 200
      #|"https://api.example.com/a/b/.." -> petstore.listPets.200: GET /a/pets -> 200
      #|
    ),
  )
}

///|
test "the prefix is percent-decoded once, then the path key is appended as it is: the key / gives a path that ends in /; in a pattern, the prefix is literal text, escaped like the rest" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "servers": [{ "url": "https://api.example.com/v1.0/caf%C3%A9%20x%2541/" }],
        #|  "paths": {
        #|    "/": { "get": { "operationId": "root", "responses": { "200": {} } } },
        #|    "/a%2541": { "get": { "operationId": "exact", "responses": { "200": {} } } },
        #|    "/files/{name}.json": { "get": { "operationId": "file", "responses": { "200": {} } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.root.200: GET /v1.0/café x%41/ -> 200
      #|petstore.exact.200: GET /v1.0/café x%41/a%41 -> 200
      #|petstore.file.200: GET pattern /v1\.0/café x\%41/files/[^/]+\.json -> 200
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/": {
        #|      "get": { "operationId": "root", "responses": { "200": {} } },
        #|      "put": { "operationId": "v1", "servers": [{ "url": "/v1" }], "responses": { "200": {} } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.root.200: GET / -> 200
      #|petstore.v1.200: PUT /v1/ -> 200
      #|
    ),
  )
}

///|
test "variables are replaced by their default; a variable that the URL uses but that has no string default is an error, at the URL or at the variable" {
  let servers = [
    (
      #|[{
      #|  "url": "https://{region}.example.com/{base}/{version}",
      #|  "variables": {
      #|    "region": { "default": "eu", "enum": ["eu", "us"] },
      #|    "base": { "default": "api/beta" },
      #|    "version": { "default": "v2" },
      #|    "unused": {}
      #|  }
      #|}]
    ),
    "[{ \"url\": \"/{version}\" }]",
    "[{ \"url\": \"/{version}\", \"variables\": { \"other\": { \"default\": \"x\" } } }]",
    "[{ \"url\": \"/{version}\", \"variables\": { \"version\": { \"enum\": [\"v1\"] } } }]",
    "[{ \"url\": \"/{version}\", \"variables\": { \"version\": { \"default\": 2 } } }]",
    "[{ \"url\": \"/{version}\", \"variables\": { \"version\": \"v1\" } }]",
    "[{ \"url\": \"/{version}\", \"variables\": [] }]",
    "[{ \"url\": \"/{a}/{b}\", \"variables\": { \"b\": {} } }]",
    "[{ \"url\": \"/{version\" }]",
    "[{ \"url\": \"/version}\" }]",
    "[{ \"url\": \"/{}\" }]",
  ]
  inspect(
    servers.map(under_servers).join(""),
    content=(
      #|petstore.listPets.200: GET /api/beta/v2/pets -> 200
      #|petstore.json: /servers/0/url: the variable {version} has no default: declare it under "variables", with a "default"
      #|nothing written
      #|petstore.json: /servers/0/url: the variable {version} has no default: declare it under "variables", with a "default"
      #|nothing written
      #|petstore.json: /servers/0/variables/version: needs "default", a string that replaces {version} in the URL
      #|nothing written
      #|petstore.json: /servers/0/variables/version/default: must be a string
      #|nothing written
      #|petstore.json: /servers/0/variables/version: must be an object
      #|nothing written
      #|petstore.json: /servers/0/variables: must be an object
      #|nothing written
      #|petstore.json: /servers/0/url: the variable {a} has no default: declare it under "variables", with a "default"
      #|petstore.json: /servers/0/variables/b: needs "default", a string that replaces {b} in the URL
      #|nothing written
      #|petstore.json: /servers/0/url: a server URL has an unbalanced { or }
      #|nothing written
      #|petstore.json: /servers/0/url: a server URL has an unbalanced { or }
      #|nothing written
      #|petstore.json: /servers/0/url: a server URL has an empty {}: a variable needs a name
      #|nothing written
      #|
    ),
  )
}

///|
test "a server URL with a query or a fragment is an error, as are servers, a server and a URL of the wrong type" {
  let servers = [
    "[{ \"url\": \"/v1?x=1\" }]", "[{ \"url\": \"https://api.example.com/v1#top\" }]",
    "[{ \"url\": \"/{v}\", \"variables\": { \"v\": { \"default\": \"v1?x\" } } }]",
    "{ \"url\": \"/v1\" }", "null", "[\"https://api.example.com/v1\"]", "[{}]", "[{ \"url\": 1 }]",
  ]
  inspect(
    servers.map(under_servers).join(""),
    content=(
      #|petstore.json: /servers/0/url: a server URL must not hold ? or #: a query or a fragment is not part of it
      #|nothing written
      #|petstore.json: /servers/0/url: a server URL must not hold ? or #: a query or a fragment is not part of it
      #|nothing written
      #|petstore.json: /servers/0/url: a server URL must not hold ? or #: a query or a fragment is not part of it
      #|nothing written
      #|petstore.json: /servers: must be an array
      #|nothing written
      #|petstore.json: /servers: must be an array
      #|nothing written
      #|petstore.json: /servers/0: must be an object
      #|nothing written
      #|petstore.json: /servers/0: needs "url", the server's URL
      #|nothing written
      #|petstore.json: /servers/0/url: must be a string
      #|nothing written
      #|
    ),
  )
}

///|
test "when the servers in one list have different paths, a warning names the one used; every server of the list is read" {
  let servers = [
    "[{ \"url\": \"https://api.example.com/v1\" }, { \"url\": \"https://staging.example.com/v1/\" }, { \"url\": \"/v1\" }]",
    "[{ \"url\": \"https://api.example.com/v1\" }, { \"url\": \"http://localhost:8080\" }, { \"url\": \"/v2\" }]",
    "[{ \"url\": \"http://localhost:8080\" }, { \"url\": \"https://api.example.com/v1\" }]",
    "[{ \"url\": \"https://{env}.example.com/{v}\", \"variables\": { \"env\": { \"default\": \"api\" }, \"v\": { \"default\": \"v1\" } } }, { \"url\": \"/v2\" }]",
    "[{ \"url\": \"/v1\" }, 1]", "[{ \"url\": \"/{v}\" }, { \"url\": \"/v1\" }]",
  ]
  inspect(
    servers.map(under_servers).join(""),
    content=(
      #|petstore.listPets.200: GET /v1/pets -> 200
      #|petstore.json: /servers: warning: left out: the servers have different paths, so only the first is used: "https://api.example.com/v1" puts "/v1" in front of the paths
      #|petstore.listPets.200: GET /v1/pets -> 200
      #|petstore.json: /servers: warning: left out: the servers have different paths, so only the first is used: "http://localhost:8080" puts nothing in front of the paths
      #|petstore.listPets.200: GET /pets -> 200
      #|petstore.json: /servers: warning: left out: the servers have different paths, so only the first is used: "https://{env}.example.com/{v}" puts "/v1" in front of the paths
      #|petstore.listPets.200: GET /v1/pets -> 200
      #|petstore.json: /servers/1: must be an object
      #|nothing written
      #|petstore.json: /servers/0/url: the variable {v} has no default: declare it under "variables", with a "default"
      #|nothing written
      #|
    ),
  )
}

///|
test "a base path replaces every prefix, and servers are then not read at all; it is decoded and trimmed like a server path, and / means no prefix" {
  let document =
    #|{
    #|  "openapi": "3.1.0",
    #|  "servers": [{ "url": "https://api.example.com/{version}" }, 1],
    #|  "paths": {
    #|    "/pets": {
    #|      "servers": "/v2",
    #|      "get": { "operationId": "listPets", "responses": { "200": {} } },
    #|      "put": { "operationId": "replacePets", "servers": [{ "url": "/v3?x" }], "responses": { "200": {} } }
    #|    },
    #|    "/pets/{petId}": { "get": { "operationId": "getPetById", "responses": { "200": {} } } }
    #|  }
    #|}
  let lines = []
  for base_path in ["/mock/petstore", "/mock/petstore/", "/", "/caf%C3%A9.v1"] {
    lines.push("--base-path \{base_path}")
    lines.push(stubs_of(document, base_path~))
  }
  inspect(
    lines.join("\n"),
    content=(
      #|--base-path /mock/petstore
      #|petstore.listPets.200: GET /mock/petstore/pets -> 200
      #|petstore.replacePets.200: PUT /mock/petstore/pets -> 200
      #|petstore.getPetById.200: GET pattern /mock/petstore/pets/[^/]+ -> 200
      #|
      #|--base-path /mock/petstore/
      #|petstore.listPets.200: GET /mock/petstore/pets -> 200
      #|petstore.replacePets.200: PUT /mock/petstore/pets -> 200
      #|petstore.getPetById.200: GET pattern /mock/petstore/pets/[^/]+ -> 200
      #|
      #|--base-path /
      #|petstore.listPets.200: GET /pets -> 200
      #|petstore.replacePets.200: PUT /pets -> 200
      #|petstore.getPetById.200: GET pattern /pets/[^/]+ -> 200
      #|
      #|--base-path /caf%C3%A9.v1
      #|petstore.listPets.200: GET /café.v1/pets -> 200
      #|petstore.replacePets.200: PUT /café.v1/pets -> 200
      #|petstore.getPetById.200: GET pattern /café\.v1/pets/[^/]+ -> 200
      #|
    ),
  )
}

///|
/// The spec's example: `getPetById` on `GET /pets/{petId}`, under the
/// server `https://api.example.com/v1`.
let pets_by_id_under_v1 : String =
  #|{
  #|  "openapi": "3.1.0",
  #|  "info": { "title": "Petstore", "version": "1.0.0" },
  #|  "servers": [{ "url": "https://api.example.com/v1" }],
  #|  "paths": {
  #|    "/pets/{petId}": {
  #|      "get": { "operationId": "getPetById", "summary": "Find a pet by ID", "responses": { "200": {} } }
  #|    }
  #|  }
  #|}

///|
test "in YAML, the comment above a Stub gives the path as written, and the comment at the top lists --base-path after the other flags" {
  inspect(
    import_to(pets_by_id_under_v1),
    content=(
      #|1 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.json
      #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets/{petId}, 200: Find a pet by ID
      #|  - id: petstore.getPetById.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path:
      #|        pattern: /v1/pets/[^/]+
      #|    response:
      #|      status: 200
      #|
    ),
  )
  inspect(
    import_to(pets_by_id_under_v1, base_path="/mock/petstore"),
    content=(
      #|1 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.json
      #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore --base-path /mock/petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets/{petId}, 200: Find a pet by ID
      #|  - id: petstore.getPetById.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path:
      #|        pattern: /mock/petstore/pets/[^/]+
      #|    response:
      #|      status: 200
      #|
    ),
  )
}

///|
test "the order compares the full generated path, prefix included, and two operations whose full paths come out the same keep the first" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/{tenant}": {
        #|      "servers": [{ "url": "/v2" }],
        #|      "get": { "operationId": "tenantRoot", "responses": { "200": {} } }
        #|    },
        #|    "/x": { "get": { "operationId": "x", "responses": { "200": {} } } },
        #|    "/pets": {
        #|      "servers": [{ "url": "/v1" }],
        #|      "get": { "operationId": "listPets", "responses": { "200": {} } }
        #|    },
        #|    "/v1/pets": {
        #|      "get": { "operationId": "listPetsToo", "responses": { "200": {} } },
        #|      "put": { "operationId": "replacePets", "responses": { "200": {} } }
        #|    },
        #|    "/{id}": { "get": { "operationId": "byId", "responses": { "200": {} } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1v1~1pets/get: warning: left out: GET "/v1/pets" is already answered by the operation at petstore.json: /paths/~1pets/get, which comes first
      #|petstore.x.200: GET /x -> 200
      #|petstore.listPets.200: GET /v1/pets -> 200
      #|petstore.replacePets.200: PUT /v1/pets -> 200
      #|petstore.tenantRoot.200: GET pattern /v2/[^/]+ -> 200
      #|petstore.byId.200: GET pattern /[^/]+ -> 200
      #|
    ),
  )
}

///|
test "the servers of a Path Item reached through a $ref are read where they are written, and each of their problems is reported once" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": { "$ref": "#/components/pathItems/A" },
        #|    "/b": { "$ref": "#/components/pathItems/A" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "A": {
        #|        "servers": [{ "url": "/v1" }, { "url": "/v2" }],
        #|        "get": { "responses": { "200": {} } }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /components/pathItems/A/servers: warning: left out: the servers have different paths, so only the first is used: "/v1" puts "/v1" in front of the paths
      #|petstore.GET /a.200: GET /v1/a -> 200
      #|petstore.GET /b.200: GET /v1/b -> 200
      #|
    ),
  )
}
