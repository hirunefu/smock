// Reading form conditions, `body: { form: … }`: a fourth kind of body
// condition, a map from field names to value conditions. Names stay
// literal, and values take the operators of query parameters.

///|
test "a form condition is read as the Schema defines it: field names, literal even with $, to value conditions with operators" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "method": "POST", "body": { "form": {
          #|  "username": "alice", "": "", "a b": { "pattern": "[0-9]+" },
          #|  "remember": { "$not": "1" }, "coupon": { "$exists": false },
          #|  "$filter": { "$not": { "$exists": true } }, "$$x": "y" } } }
        ),
      ),
      stub_with("empty", "\"request\": { \"body\": { \"form\": {} } }"),
    ]),
    content="valid",
  )
}

///|
test "a malformed form condition is a diagnostic at its JSON Pointer, and a body condition gives only one kind of condition" {
  inspect(
    stub_problems([
      stub_with("a", "\"request\": { \"body\": { \"form\": [\"a=1\"] } }"),
      stub_with(
        "b",
        (
          #|"request": { "body": { "form": { "a": 1, "b": { "pattern": "(" },
          #|  "c": { "$nto": "1" }, "d": { "$includes": "x" },
          #|  "e": { "$exists": "yes" }, "f": { "$not": "1", "pattern": "x" } } } }
        ),
      ),
      stub_with(
        "c", "\"request\": { \"body\": { \"form\": { \"a\": \"1\" }, \"json\": {} } }",
      ),
      stub_with(
        "d", "\"request\": { \"body\": { \"pattern\": \".*\", \"form\": { \"a\": \"1\" }, \"json\": {} } }",
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/form: must be an object
      #|a.json: /stubs/1/request/body/form/a: must be a string or an object
      #|a.json: /stubs/1/request/body/form/b/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/1/request/body/form/c/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
      #|a.json: /stubs/1/request/body/form/d/$includes: is allowed only in a json condition
      #|a.json: /stubs/1/request/body/form/e/$exists: must be true or false
      #|a.json: /stubs/1/request/body/form/f/pattern: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/2/request/body: has "json" and "form"; give only one of "json", "pattern", "form" or "xml"
      #|a.json: /stubs/3/request/body: has "json" and "pattern" and "form"; give only one of "json", "pattern", "form" or "xml"
    ),
  )
}

///|
test "a form condition shadows a later one that has each of its fields with the same condition, in any order; any other body condition, or none, gives no warning" {
  let form = (fields : String) => "{ \"body\": { \"form\": \{fields} } }"
  inspect(
    verdicts([
      (
        form("{ \"a\": \"1\" }"),
        form("{ \"a\": \"1\", \"b\": { \"$not\": \"2\" } }"),
      ),
      (
        form("{ \"b\": { \"$not\": \"2\" }, \"a\": \"1\" }"),
        form("{ \"a\": \"1\", \"b\": { \"$not\": \"2\" } }"),
      ),
      ("{}", form("{ \"a\": \"1\" }")),
      (form("{ \"a\": \"1\", \"c\": \"3\" }"), form("{ \"a\": \"1\" }")),
      (form("{ \"a\": \"1\" }"), form("{ \"a\": { \"pattern\": \"1\" } }")),
      (form("{ \"a\": \"1\" }"), form("{ \"A\": \"1\" }")),
      (form("{ \"a\": \"1\" }"), "{}"),
      (form("{ \"a\": \"1\" }"), "{ \"query\": { \"a\": \"1\" } }"),
      (form("{ \"a\": \"1\" }"), "{ \"body\": \"a=1\" }"),
      ("{ \"body\": \"a=1\" }", form("{ \"a\": \"1\" }")),
    ]),
    content=(
      #|t { "body": { "form": { "a": "1" } } } / s { "body": { "form": { "a": "1", "b": { "$not": "2" } } } } -> shadowed
      #|t { "body": { "form": { "b": { "$not": "2" }, "a": "1" } } } / s { "body": { "form": { "a": "1", "b": { "$not": "2" } } } } -> shadowed
      #|t {} / s { "body": { "form": { "a": "1" } } } -> shadowed
      #|t { "body": { "form": { "a": "1", "c": "3" } } } / s { "body": { "form": { "a": "1" } } } -> not reported
      #|t { "body": { "form": { "a": "1" } } } / s { "body": { "form": { "a": { "pattern": "1" } } } } -> not reported
      #|t { "body": { "form": { "a": "1" } } } / s { "body": { "form": { "A": "1" } } } -> not reported
      #|t { "body": { "form": { "a": "1" } } } / s {} -> not reported
      #|t { "body": { "form": { "a": "1" } } } / s { "query": { "a": "1" } } -> not reported
      #|t { "body": { "form": { "a": "1" } } } / s { "body": "a=1" } -> not reported
      #|t { "body": "a=1" } / s { "body": { "form": { "a": "1" } } } -> not reported
    ),
  )
}
