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
      #|a.json: /stubs/0/request/query/q/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
      #|a.json: /stubs/0/request/headers/X-A/$not/$regex: is not an operator: the operators here are $not, $exists; write $$regex for a literal key that starts with $
      #|a.json: /stubs/0/request/headers/X-B/$: is not an operator: the operators here are $not, $exists; write $$ for a literal key that starts with $
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
