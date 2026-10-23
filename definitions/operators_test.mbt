// Reading the operators of value conditions: in a value position, an
// object whose only key starts with `$` is an operator, such as `$not` or
// `$exists`. Names stay literal.

///|
test "$not and $exists in query and header values are read as the Schema defines them, and nest" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": {
          #|  "query": { "q": { "$not": "1" }, "r": { "$not": { "pattern": "[0-9]+" } },
          #|    "s": { "$exists": true }, "t": { "$exists": false } },
          #|  "headers": { "X-A": { "$not": { "$not": { "$exists": false } } },
          #|    "X-B": { "$not": { "$exists": true } } } }
        ),
      ),
      stub_with(
        "names",
        (
          #|"request": { "query": { "$filter": "x", "$$top": { "$exists": true } },
          #|  "headers": { "$X": { "pattern": ".*" } } }
        ),
      ),
    ]),
    content="valid",
  )
}

///|
test "a malformed operator in a query or header value is a diagnostic at its JSON Pointer" {
  inspect(
    stub_problems([
      stub_with(
        "unknown",
        (
          #|"request": { "query": { "q": { "$nto": "1" } },
          #|  "headers": { "X-A": { "$not": { "$regex": "a" } }, "X-B": { "$": "b" } } }
        ),
      ),
      stub_with(
        "beside",
        (
          #|"request": { "query": { "q": { "$not": "1", "pattern": "2" } },
          #|  "headers": { "X-A": { "pattern": "a", "$exists": true },
          #|    "X-B": { "$not": "b", "$exists": false } } }
        ),
      ),
      stub_with(
        "exists",
        (
          #|"request": { "query": { "q": { "$exists": "true" }, "r": { "$exists": null } },
          #|  "headers": { "X-A": { "$not": { "$exists": 1 } } } }
        ),
      ),
      stub_with(
        "includes", "\"request\": { \"query\": { \"tags\": { \"$includes\": \"a\" } } }",
      ),
      stub_with(
        "operand",
        (
          #|"request": { "query": { "q": { "$not": 1 }, "r": { "$not": {} } },
          #|  "headers": { "X-A": { "$not": { "pattern": "(" } } } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/query/q/$nto: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/0/request/headers/X-A/$not/$regex: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/0/request/headers/X-B/$: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/1/request/query/q/pattern: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/1/request/headers/X-A/pattern: is not allowed beside "$exists": an operator is the only key of its object
      #|a.json: /stubs/1/request/headers/X-B/$exists: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/2/request/query/q/$exists: must be true or false
      #|a.json: /stubs/2/request/query/r/$exists: must be true or false
      #|a.json: /stubs/2/request/headers/X-A/$not/$exists: must be true or false
      #|a.json: /stubs/3/request/query/tags/$includes: is allowed only in a json condition
      #|a.json: /stubs/4/request/query/q/$not: must be a string or an object
      #|a.json: /stubs/4/request/query/r/$not: needs "pattern"
      #|a.json: /stubs/4/request/headers/X-A/$not/pattern: is not a valid pattern: position 0: missing closing )
    ),
  )
}

///|
test "unknown $ keys, operators allowed only in json and keys beside an operator are reported the same whatever the order of the keys" {
  // Each object is given twice, its keys in one order and then the other.
  let objects = [
    (
      "query", "{ \"$foo\": 1, \"$not\": \"2\" }", "{ \"$not\": \"2\", \"$foo\": 1 }",
    ),
    (
      "query", "{ \"$foo\": 1, \"$includes\": \"2\" }", "{ \"$includes\": \"2\", \"$foo\": 1 }",
    ),
    (
      "query", "{ \"$exists\": true, \"$not\": \"2\" }", "{ \"$not\": \"2\", \"$exists\": true }",
    ),
    (
      "query", "{ \"pattern\": \"x\", \"$includes\": \"2\" }", "{ \"$includes\": \"2\", \"pattern\": \"x\" }",
    ),
    (
      "json", "{ \"$foo\": 1, \"$not\": 2, \"b\": 3 }", "{ \"b\": 3, \"$not\": 2, \"$foo\": 1 }",
    ),
    (
      "json", "{ \"$includes\": 1, \"$exists\": true }", "{ \"$exists\": true, \"$includes\": 1 }",
    ),
  ]
  let out = []
  for object in objects {
    let (place, first, second) = object
    let stub = (object : String) => {
      let request = if place == "query" {
        "\"request\": { \"query\": { \"q\": \{object} } }"
      } else {
        "\"request\": { \"body\": { \"json\": { \"q\": \{object} } } }"
      }
      stub_with("s", request)
    }
    // The problems come in the order of the keys, so they are compared as
    // sets.
    let problems = (object : String) => {
      let lines = stub_problems([stub(object)])
        .split("\n")
        .map(line => line.to_owned())
        .to_array()
      lines.sort()
      lines.join("\n")
    }
    let one = problems(first)
    let other = problems(second)
    out.push(
      if one == other {
        one
      } else {
        "\{one}\n  but reversed:\n\{other}"
      },
    )
  }
  inspect(
    out.join("\n"),
    content=(
      #|a.json: /stubs/0/request/query/q/$foo: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/0/request/query/q/$includes: is allowed only in a json condition
      #|a.json: /stubs/0/request/query/q/$foo: is not an operator: the operators here are "$not" and "$exists"
      #|a.json: /stubs/0/request/query/q/$exists: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/0/request/query/q/$includes: is allowed only in a json condition
      #|a.json: /stubs/0/request/query/q/pattern: is not allowed beside "$includes": an operator is the only key of its object
      #|a.json: /stubs/0/request/body/json/q/b: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/0/request/body/json/q/$foo: is not an operator: the operators here are "$not", "$exists", "$includes" and "$last"; write "$$foo" for the literal key "$foo"
      #|a.json: /stubs/0/request/body/json/q/$includes: is not allowed beside "$exists": an operator is the only key of its object
    ),
  )
}
