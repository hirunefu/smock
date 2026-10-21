///|
test "a Path Item $ref and a Response $ref are followed within the document, as if the parts they name were written in place" {
  inspect(
    import_json(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets": { "$ref": "#/components/pathItems/Pets" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "Pets": {
        #|        "get": {
        #|          "operationId": "listPets",
        #|          "responses": { "200": { "$ref": "#/components/responses/Ok" } }
        #|        }
        #|      }
        #|    },
        #|    "responses": {
        #|      "Ok": { "description": "OK" }
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
test "a $ref in a response other than the main one is followed too, and one that cannot be followed is an error at the $ref" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets/mine": {
        #|      "get": {
        #|        "operationId": "getPet",
        #|        "responses": {
        #|          "200": { "description": "My pet" },
        #|          "404": { "$ref": "#/components/responses/NotFound" },
        #|          "default": { "$ref": "#/components/responses/Problem" }
        #|        }
        #|      }
        #|    }
        #|  },
        #|  "components": {
        #|    "responses": {
        #|      "NotFound": { "description": "No pet" },
        #|      "Problem": { "$ref": "#/components/responses/Error" },
        #|      "Error": { "description": "Error", "content": { "application/problem+json": {} } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.getPet.404: GET /pets/mine -> 404
      #|petstore.getPet.default: GET /pets/mine -> 500
      #|petstore.getPet.200: GET /pets/mine -> 200
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets/mine": {
        #|      "get": {
        #|        "responses": {
        #|          "200": { "description": "My pet" },
        #|          "404": { "$ref": "#/components/responses/Missing" }
        #|        }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1pets~1mine/get/responses/404/$ref: the document has nothing at /components/responses/Missing
      #|nothing written
      #|
    ),
  )
}

///|
test "a problem in a referenced part is reported where it is written, once however many references reach it, and operations reached through a Path Item $ref keep the order of the path keys; a $ref that names a Reference Object is followed on" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/b": { "$ref": "#/components/pathItems/B" },
        #|    "/a": {
        #|      "get": { "responses": { "200": { "$ref": "#/components/responses/Ok" } } }
        #|    },
        #|    "/c": { "$ref": "#/components/pathItems/C" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "C": { "get": { "responses": { "201": { "$ref": "#/components/responses/Created" } } } },
        #|      "B": {
        #|        "put": { "responses": { "200": {}, "404": {} } },
        #|        "get": { "responses": { "200": {} } }
        #|      }
        #|    },
        #|    "responses": {
        #|      "Ok": {
        #|        "description": "OK",
        #|        "headers": { "X-Rate-Limit": { "example": null } },
        #|        "content": { "application/json": {} }
        #|      },
        #|      "Created": { "$ref": "#/components/responses/Ok" }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /components/responses/Ok/headers/X-Rate-Limit/example: warning: left out: a header cannot hold null
      #|petstore.PUT /b.404: PUT /b -> 404
      #|petstore.PUT /b.200: PUT /b -> 200
      #|petstore.GET /b.200: GET /b -> 200
      #|petstore.GET /a.200: GET /a -> 200
      #|petstore.GET /c.201: GET /c -> 201
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": { "$ref": "#/components/pathItems/A" },
        #|    "/b": { "get": { "responses": { "200": { "$ref": "#/components/responses/B" } } } }
        #|  },
        #|  "components": {
        #|    "pathItems": { "A": [] },
        #|    "responses": { "B": "OK" }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /components/pathItems/A: must be an object
      #|petstore.json: /components/responses/B: must be an object
      #|nothing written
      #|
    ),
  )
}

///|
test "a fragment is an RFC 6901 JSON Pointer, percent-decoded, with ~0 and ~1, that may step into arrays" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": { "$ref": "#/components/pathItems/a~1b~0c" },
        #|    "/b": { "$ref": "#/components/pathItems/with%20a%20space" },
        #|    "/c": { "$ref": "#/x-items/1" },
        #|    "/d": { "get": { "responses": { "200": { "$ref": "#/components/responses/R%C3%A9ponse" } } } },
        #|    "/e": { "get": { "responses": { "201": { "$ref": "#/x-items/0/responses/201" } } } }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "a/b~c": { "get": { "responses": { "200": {} } } },
        #|      "with a space": { "get": { "responses": { "202": {} } } }
        #|    },
        #|    "responses": { "Réponse": { "description": "OK" } }
        #|  },
        #|  "x-items": [
        #|    { "responses": { "201": { "description": "Created" } } },
        #|    { "put": { "responses": { "204": {} } } }
        #|  ]
        #|}
      ),
    ),
    content=(
      #|petstore.GET /a.200: GET /a -> 200
      #|petstore.GET /b.202: GET /b -> 202
      #|petstore.PUT /c.204: PUT /c -> 204
      #|petstore.GET /d.200: GET /d -> 200
      #|petstore.GET /e.201: GET /e -> 201
      #|
    ),
  )
}

///|
test "a $ref that cannot be followed is an error at the $ref: one that is not a string, that names nothing, whose fragment is not a JSON Pointer, that is a URL or an absolute path, or that names another file" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": { "$ref": 7 },
        #|    "/b": { "$ref": "#/components/pathItems/Missing" },
        #|    "/c": { "$ref": "#/x-items/01" },
        #|    "/d": { "$ref": "#/x-items/-" },
        #|    "/e": { "$ref": "#/x-items/1" },
        #|    "/f": { "$ref": "#/x-items/0/get/x" },
        #|    "/g": { "$ref": "#Pets" },
        #|    "/h": { "$ref": "#/components/pathItems/a~2b" },
        #|    "/i": { "$ref": "#/components/pathItems/a~" },
        #|    "/j": { "$ref": "https://example.com/api.json#/components/pathItems/Pets" },
        #|    "/k": { "$ref": "file:///api/pets.json" },
        #|    "/l": { "$ref": "urn:example:pets" },
        #|    "/m": { "$ref": "//example.com/api.json" },
        #|    "/n": { "$ref": "/api/pets.json#/Pets" },
        #|    "/o": { "$ref": "pets.json#/Pets" },
        #|    "/p": { "$ref": "./common/pets.yaml" },
        #|    "/q": { "get": { "responses": { "200": { "$ref": ["#/components/responses/Ok"] } } } },
        #|    "/r": { "get": { "responses": { "200": { "$ref": "#/components/responses/Missing" } } } }
        #|  },
        #|  "x-items": [{ "get": { "responses": { "200": {} } } }]
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/$ref: must be a string
      #|petstore.json: /paths/~1b/$ref: the document has nothing at /components/pathItems/Missing
      #|petstore.json: /paths/~1c/$ref: the document has nothing at /x-items/01
      #|petstore.json: /paths/~1d/$ref: the document has nothing at /x-items/-
      #|petstore.json: /paths/~1e/$ref: the document has nothing at /x-items/1
      #|petstore.json: /paths/~1f/$ref: the document has nothing at /x-items/0/get/x
      #|petstore.json: /paths/~1g/$ref: the fragment must be a JSON Pointer, such as #/components/responses/Ok: smock does not look up $anchor names
      #|petstore.json: /paths/~1h/$ref: the fragment must be a JSON Pointer: ~ is written ~0 in it, and / in a key ~1
      #|petstore.json: /paths/~1i/$ref: the fragment must be a JSON Pointer: ~ is written ~0 in it, and / in a key ~1
      #|petstore.json: /paths/~1j/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1k/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1l/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1m/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1n/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1o/$ref: references to other files are not followed yet: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1p/$ref: references to other files are not followed yet: bundle the document into one file first, with another tool
      #|petstore.json: /paths/~1q/get/responses/200/$ref: must be a string
      #|petstore.json: /paths/~1r/get/responses/200/$ref: the document has nothing at /components/responses/Missing
      #|nothing written
      #|
    ),
  )
}

///|
test "a cycle of Reference Objects is an error at the $ref that closes it, reported once however many references lead into it" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": { "$ref": "#/paths/~1a" },
        #|    "/b": { "$ref": "#/components/pathItems/B1" },
        #|    "/c": { "get": { "responses": { "200": { "$ref": "#/components/responses/R1" } } } },
        #|    "/d": { "$ref": "#/components/pathItems/B1" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "B1": { "$ref": "#/components/pathItems/B2" },
        #|      "B2": { "$ref": "#/components/pathItems/B1" }
        #|    },
        #|    "responses": {
        #|      "R1": { "$ref": "#/components/responses/R2" },
        #|      "R2": { "$ref": "#/components/responses/R1" }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/$ref: a cycle of references: this one leads back to petstore.json: /paths/~1a
      #|petstore.json: /components/pathItems/B2/$ref: a cycle of references: this one leads back to petstore.json: /components/pathItems/B1
      #|petstore.json: /components/responses/R2/$ref: a cycle of references: this one leads back to petstore.json: /components/responses/R1
      #|nothing written
      #|
    ),
  )
}

///|
test "the fields beside a Path Item's $ref are ignored with a warning, x- extensions without one; those beside a Response's $ref are ignored, as OpenAPI asks" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": {
        #|      "summary": "A",
        #|      "$ref": "#/components/pathItems/A",
        #|      "get": { "responses": { "201": {} } },
        #|      "x-internal": true,
        #|      "servers": []
        #|    },
        #|    "/b": {
        #|      "get": {
        #|        "responses": {
        #|          "200": {
        #|            "$ref": "#/components/responses/Ok",
        #|            "description": "Overridden",
        #|            "content": { "application/json": {} },
        #|            "headers": "not read"
        #|          }
        #|        }
        #|      }
        #|    }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "A": { "put": { "responses": { "200": {} } } }
        #|    },
        #|    "responses": { "Ok": { "description": "OK" } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1a/summary: warning: ignored: a field beside a Path Item's $ref has no defined meaning
      #|petstore.json: /paths/~1a/get: warning: ignored: a field beside a Path Item's $ref has no defined meaning
      #|petstore.json: /paths/~1a/servers: warning: ignored: a field beside a Path Item's $ref has no defined meaning
      #|petstore.PUT /a.200: PUT /a -> 200
      #|petstore.GET /b.200: GET /b -> 200
      #|
    ),
  )
}

///|
test "$id at the root of the document and 3.2's $self are ignored: a reference names a part of the document by its fragment, and a URL is not read even when it names the document itself" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.2.0",
        #|  "$self": "https://example.com/api/openapi.json",
        #|  "$id": "https://example.com/other/openapi.json",
        #|  "paths": {
        #|    "/a": { "$ref": "#/components/pathItems/A" },
        #|    "/b": { "$ref": "https://example.com/api/openapi.json#/components/pathItems/A" }
        #|  },
        #|  "components": {
        #|    "pathItems": { "A": { "get": { "responses": { "200": {} } } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1b/$ref: smock reads no URLs and no absolute paths: bundle the document into one file first, with another tool
      #|nothing written
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.2.0",
        #|  "$self": "https://example.com/api/openapi.json",
        #|  "$id": "https://example.com/other/openapi.json",
        #|  "paths": { "/a": { "$ref": "#/components/pathItems/A" } },
        #|  "components": {
        #|    "pathItems": { "A": { "get": { "responses": { "200": {} } } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.GET /a.200: GET /a -> 200
      #|
    ),
  )
}

///|
test "references in parts the converter does not read are not followed, and a broken one there is no error: request bodies, parameters, security, callbacks, webhooks, links, 1xx responses, unreached components, and $ref where OpenAPI allows no Reference Object" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/a": {
        #|      "parameters": [{ "$ref": "#/nowhere" }],
        #|      "get": {
        #|        "$ref": "#/nowhere",
        #|        "parameters": [{ "$ref": "https://example.com/p.json" }],
        #|        "requestBody": { "$ref": "other.json#/Body" },
        #|        "security": [{ "$ref": "#/nowhere" }],
        #|        "callbacks": { "onEvent": { "$ref": "#/nowhere" } },
        #|        "responses": {
        #|          "200": { "description": "OK", "links": { "next": { "$ref": "#/nowhere" } } },
        #|          "101": { "$ref": "#/nowhere" }
        #|        }
        #|      }
        #|    },
        #|    "/b": { "get": { "responses": { "$ref": "#/nowhere" } } }
        #|  },
        #|  "webhooks": { "w": { "$ref": "#/nowhere" } },
        #|  "components": {
        #|    "pathItems": { "Unreached": { "$ref": "#/nowhere" } },
        #|    "responses": { "Unreached": { "$ref": 7 } },
        #|    "schemas": { "Broken": { "$ref": "#Anchor" } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /webhooks: warning: webhooks are not imported: they are requests the API sends, not ones it answers
      #|petstore.json: /paths/~1a/get/callbacks: warning: callbacks are not imported
      #|petstore.json: /paths/~1a/get/responses/101: warning: left out: smock answers with a status from 200 to 599
      #|petstore.json: /paths/~1b/get/responses/$ref: warning: left out: a response key is a status code from 100 to 599, a range from 1XX to 5XX, default or an x- extension
      #|petstore.json: /paths/~1b/get/responses: warning: has no responses: the operation answers 200 with an empty body
      #|petstore.GET /a.200: GET /a -> 200
      #|petstore.GET /b.200: GET /b -> 200
      #|
    ),
  )
}

///|
test "a Path Item that two path keys name gives each its operations; an operationId in it is then used twice, which is an error that names the earlier path key" {
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets": { "$ref": "#/components/pathItems/Pets" },
        #|    "/v2/pets": { "$ref": "#/components/pathItems/Pets" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "Pets": {
        #|        "get": { "responses": { "200": {} } },
        #|        "post": { "operationId": "addPet", "responses": { "201": {} } }
        #|      }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /components/pathItems/Pets/post/operationId: the operationId "addPet" is already used under the path key "/pets", which names the same Path Item
      #|nothing written
      #|
    ),
  )
  inspect(
    stubs_of(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets": { "$ref": "#/components/pathItems/Pets" },
        #|    "/v2/pets": { "$ref": "#/components/pathItems/Pets" }
        #|  },
        #|  "components": {
        #|    "pathItems": {
        #|      "Pets": { "get": { "responses": { "200": {} } } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.GET /pets.200: GET /pets -> 200
      #|petstore.GET /v2/pets.200: GET /v2/pets -> 200
      #|
    ),
  )
}
