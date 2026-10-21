///|
test "each header a response documents is written in its headers with its example, after the Content-Type, in the order the document writes them" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Request-Id": { "example": "req-1" },
        #|      "X-Rate-Limit": { "example": 100 }
        #|    },
        #|    "content": { "text/plain": { "example": "OK" } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 200
      #|  headers:
      #|    Content-Type: text/plain
      #|    X-Request-Id: req-1
      #|    X-Rate-Limit: "100"
      #|  body: OK
      #|
    ),
  )
}

///|
test "a header's value is its example, else the first of its examples that gives one, else a sample of its schema; with none, it is empty" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Example": {
        #|        "example": "from-example",
        #|        "examples": { "a": { "value": "from-examples" } },
        #|        "schema": { "type": "string" }
        #|      },
        #|      "X-Examples": {
        #|        "examples": {
        #|          "far": { "externalValue": "https://example.com/a.txt" },
        #|          "first": { "value": "first" },
        #|          "second": { "value": "second" }
        #|        },
        #|        "schema": { "type": "string" }
        #|      },
        #|      "X-Rate-Limit": { "schema": { "type": "integer", "minimum": 10 } },
        #|      "X-Expires": { "schema": { "type": "string", "format": "date-time" } },
        #|      "X-Schema-Example": { "schema": { "type": "string", "example": "abc" } },
        #|      "X-Nothing": { "description": "Neither an example nor a schema" }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Example/examples: warning: ignored: a header is written with its example, which comes first
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Examples/examples/far: warning: left out: smock does not read externalValue, and the example has no dataValue, value or serializedValue
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Examples/examples/second: warning: left out: a header is written with its first example
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Example: from-example
      #|    X-Examples: first
      #|    X-Rate-Limit: "10"
      #|    X-Expires: "2000-01-01T00:00:00Z"
      #|    X-Schema-Example: abc
      #|    X-Nothing: ""
      #|
    ),
  )
}

///|
test "an Example Object gives a header its serializedValue first, since it is the exact header text, then its dataValue, then its value" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Serialized": {
        #|        "examples": {
        #|          "a": { "serializedValue": "1,2", "dataValue": [3, 4], "value": [5, 6] }
        #|        }
        #|      },
        #|      "X-Data": { "examples": { "a": { "dataValue": "data", "value": "value" } } },
        #|      "X-Value": { "examples": { "a": { "value": "value" } } }
        #|    }
        #|  }
        #|}
      ),
      openapi="3.2.0",
    ),
    content=(
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Serialized: 1,2
      #|    X-Data: data
      #|    X-Value: value
      #|
    ),
  )
}

///|
test "a header's number is written as smock writes numbers, a boolean as true or false, and an array of scalars joined with commas, as style simple asks" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Price": { "example": 1.50 },
        #|      "X-Big": { "example": 12345678901234567890 },
        #|      "X-Exponent": { "example": 1e3 },
        #|      "X-Flag": { "example": true },
        #|      "X-Off": { "schema": { "const": false } },
        #|      "X-List": { "example": ["a", 1, false] },
        #|      "X-Sampled-List": {
        #|        "schema": { "type": "array", "minItems": 3, "items": { "type": "integer", "minimum": 7 } }
        #|      },
        #|      "X-Empty-List": { "example": [] },
        #|      "X-Tab": { "example": "a\tb" }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Price: "1.5"
      #|    X-Big: "12345678901234567890"
      #|    X-Exponent: "1000"
      #|    X-Flag: "true"
      #|    X-Off: "false"
      #|    X-List: a,1,false
      #|    X-Sampled-List: 7,7,7
      #|    X-Empty-List: ""
      #|    X-Tab: "a\tb"
      #|
    ),
  )
}

///|
test "Content-Type, Content-Length, Transfer-Encoding and Connection, in any case, are skipped without a warning, and not read: OpenAPI says to skip the first, and smock sets the others itself" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "content-type": { "example": "text/html" },
        #|      "Content-Length": { "schema": { "type": "integer" } },
        #|      "TRANSFER-ENCODING": { "example": { "not": "a scalar" } },
        #|      "Connection": { "$ref": "#/nowhere" },
        #|      "X-Kept": { "example": "kept" }
        #|    },
        #|    "content": { "application/json": { "example": { "id": 1 } } }
        #|  }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Kept: kept
      #|  json:
      #|    id: 1
      #|
    ),
  )
}

///|
test "a header is left out with a warning when its name is Smock-Mock, is not an HTTP token or repeats an earlier one in another case, or when its value is an object or null, holds one, or holds a control character" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "smock-mock": { "example": "users; via=default" },
        #|      "X Spaced": { "example": "a" },
        #|      "X-Id": { "example": "first" },
        #|      "x-id": { "$ref": "#/nowhere" },
        #|      "X-Object": { "example": { "a": 1 } },
        #|      "X-Null": { "examples": { "a": { "value": null } } },
        #|      "X-Sampled-Object": { "schema": { "type": "object" } },
        #|      "X-Nested": { "example": ["a", ["b"]] },
        #|      "X-Null-Item": { "example": ["a", null] },
        #|      "X-Newline": { "example": "a\r\nSet-Cookie: x" },
        #|      "X-Serialized-Newline": { "examples": { "a": { "serializedValue": "a\nb" } } },
        #|      "X-Item-Newline": { "example": ["a", "b\u0000"] },
        #|      "X-Kept": { "example": "kept" }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/smock-mock: warning: left out: smock adds Smock-Mock itself, when the Default Mock answers
      #|petstore.json: /paths/~1r/get/responses/200/headers/X Spaced: warning: left out: a header name must be an HTTP token, such as X-Rate-Limit
      #|petstore.json: /paths/~1r/get/responses/200/headers/x-id: warning: left out: the header name "X-Id" is already given: header names are case-insensitive
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Object/example: warning: left out: a header cannot hold an object
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Null/examples/a/value: warning: left out: a header cannot hold null
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Sampled-Object/schema: warning: left out: a header cannot hold an object
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Nested/example: warning: left out: a header cannot hold an array that holds an array
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Null-Item/example: warning: left out: a header cannot hold an array that holds null
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Newline/example: warning: left out: a header cannot hold a control character
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Serialized-Newline/examples/a/serializedValue: warning: left out: a header cannot hold a control character
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Item-Newline/example: warning: left out: a header cannot hold a control character
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Id: first
      #|    X-Kept: kept
      #|
    ),
  )
}

///|
test "a Header Object and a header's Example Object reached through a Reference Object are followed, and every Stub of the response, its named examples' included, sends the headers" {
  inspect(
    import_to(
      (
        #|{
        #|  "openapi": "3.1.0",
        #|  "paths": {
        #|    "/pets": {
        #|      "get": {
        #|        "operationId": "listPets",
        #|        "responses": {
        #|          "200": {
        #|            "headers": {
        #|              "X-Rate-Limit": { "$ref": "#/components/headers/RateLimit" },
        #|              "X-Request-Id": { "examples": { "a": { "$ref": "#/components/examples/RequestId" } } }
        #|            },
        #|            "content": {
        #|              "application/json": {
        #|                "examples": { "cat": { "value": ["Tom"] }, "dog": { "value": ["Rex"] } }
        #|              }
        #|            }
        #|          },
        #|          "429": { "$ref": "#/components/responses/TooMany" }
        #|        }
        #|      }
        #|    }
        #|  },
        #|  "components": {
        #|    "headers": {
        #|      "RateLimit": { "$ref": "#/components/headers/Limit" },
        #|      "Limit": { "schema": { "type": "integer", "minimum": 100 } }
        #|    },
        #|    "examples": { "RequestId": { "value": "req-1" } },
        #|    "responses": {
        #|      "TooMany": { "headers": { "Retry-After": { "example": 60 } } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|3 Stubs from 1 operations
      #|# Generated by smock import-openapi from petstore.json
      #|# (OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets, 429
      #|  - id: petstore.listPets.429
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /pets
      #|      headers:
      #|        Smock-Status: "429"
      #|    response:
      #|      status: 429
      #|      headers:
      #|        Retry-After: "60"
      #|  # GET /pets, 200, example dog
      #|  - id: petstore.listPets.200.dog
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /pets
      #|      headers:
      #|        Smock-Example: dog
      #|    response:
      #|      status: 200
      #|      headers:
      #|        X-Rate-Limit: "100"
      #|        X-Request-Id: req-1
      #|      json:
      #|        - Rex
      #|  # GET /pets, 200, example cat
      #|  - id: petstore.listPets.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /pets
      #|    response:
      #|      status: 200
      #|      headers:
      #|        X-Rate-Limit: "100"
      #|        X-Request-Id: req-1
      #|      json:
      #|        - Tom
      #|
    ),
  )
}

///|
test "a Header Object that is not an object, or whose $ref cannot be followed, is an error at its pointer" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Text": "a",
        #|      "X-Missing": { "$ref": "#/components/headers/Missing" },
        #|      "X-Loop": { "$ref": "#/paths/~1r/get/responses/200/headers/X-Loop" },
        #|      "X-Examples": { "examples": [] },
        #|      "X-Schema": { "schema": 1 }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Text: must be an object
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Missing/$ref: the document has nothing at /components/headers/Missing
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Loop/$ref: a cycle of references: this one leads back to petstore.json: /paths/~1r/get/responses/200/headers/X-Loop
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Examples/examples: must be an object
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Schema/schema: must be a schema, an object or a boolean
      #|nothing written
      #|
    ),
  )
}

///|
test "a header described with content takes its value the same way from its media type, after following its $ref: its example, else the first of its examples, else a sample of its schema" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Example": { "content": { "text/plain": { "example": "abc" } } },
        #|      "X-Serialized": {
        #|        "content": {
        #|          "application/json": {
        #|            "examples": { "a": { "serializedValue": "{\"a\":1}", "value": { "a": 1 } } }
        #|          }
        #|        }
        #|      },
        #|      "X-Schema": { "content": { "text/plain": { "schema": { "type": "integer", "minimum": 3 } } } },
        #|      "X-Reference": {
        #|        "content": { "text/plain": { "$ref": "#/paths/~1r/get/responses/200/headers/X-Example/content/text~1plain" } }
        #|      },
        #|      "X-Two": { "content": { "text/plain": { "example": "one" }, "text/csv": { "example": "two" } } },
        #|      "X-Own-Example": { "example": "own", "content": { "text/plain": { "example": "content" } } },
        #|      "X-Beside-Schema": {
        #|        "schema": { "type": "string" },
        #|        "content": { "text/plain": { "example": "content" } }
        #|      },
        #|      "X-Empty": { "content": {} }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Two/content/text~1csv: warning: left out: a header's content has one media type, here "text/plain"
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Beside-Schema/schema: warning: ignored: the header has content, which comes first
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Example: abc
      #|    X-Serialized: "{\"a\":1}"
      #|    X-Schema: "3"
      #|    X-Reference: abc
      #|    X-Two: one
      #|    X-Own-Example: own
      #|    X-Beside-Schema: content
      #|    X-Empty: ""
      #|
    ),
  )
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Content": { "content": [] },
        #|      "X-Media-Type": { "content": { "text/plain": "abc" } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Content/content: must be an object
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Media-Type/content/text~1plain: must be an object
      #|nothing written
      #|
    ),
  )
}

///|
test "a response that has no body still sends its headers: a 204, and a response to HEAD" {
  inspect(
    responses_of(
      (
        #|{
        #|  "204": { "headers": { "X-Deleted": { "example": 1 } } }
        #|}
      ),
    ),
    content=(
      #|response:
      #|  status: 204
      #|  headers:
      #|    X-Deleted: "1"
      #|
    ),
  )
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": { "X-Total": { "schema": { "type": "integer" } } },
        #|    "content": { "application/json": { "example": [] } }
        #|  }
        #|}
      ),
      meth="head",
    ),
    content=(
      #|petstore.json: /paths/~1r/head/responses/200/content: warning: left out: a response to HEAD has no body
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Total: "0"
      #|
    ),
  )
}

///|
test "a header's sample is bounded as a body's: one that would pass 1 MiB, even cut to its required parts, leaves the value empty, with a warning, and stops as soon as it passes" {
  inspect(
    responses_of(
      (
        #|{
        #|  "200": {
        #|    "headers": {
        #|      "X-Huge": { "schema": { "type": "string", "minLength": 1000000000 } },
        #|      "X-Small": { "schema": { "type": "string", "minLength": 3 } }
        #|    }
        #|  }
        #|}
      ),
    ),
    content=(
      #|petstore.json: /paths/~1r/get/responses/200/headers/X-Huge/schema: warning: left out: the header's value is empty, since its sample would be more than 1 MiB, even cut to its required parts
      #|response:
      #|  status: 200
      #|  headers:
      #|    X-Huge: ""
      #|    X-Small: string
      #|
    ),
  )
}
