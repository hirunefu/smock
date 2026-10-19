// Reading `xml` body conditions: paths into an XML body, compiled when the
// definition set loads, each with a value condition.

///|
test "an xml condition maps paths, to elements or a final attribute, to value conditions with operators" {
  inspect(
    stub_problems([
      stub_with(
        "a",
        (
          #|"request": { "body": { "xml": {
          #|  "/Envelope/Body/GetUser/id": "42", "/order/@status": { "pattern": "paid|shipped" },
          #|  "/order/coupon": { "$exists": false }, "/order/@tier": { "$not": { "pattern": "vip.*" } },
          #|  "/é/_x.y-z": "" } } }
        ),
      ),
      stub_with("empty", "\"request\": { \"body\": { \"xml\": {} } }"),
    ]),
    content="valid",
  )
}

///|
test "a malformed path is a diagnostic at its JSON Pointer, with the position of the problem in the path" {
  inspect(
    stub_problems([
      stub_with(
        "paths",
        (
          #|"request": { "body": { "xml": {
          #|  "order/id": "1", "/order//id": "1", "/order/*": "1", "/soap:Envelope": "1",
          #|  "/order/item[1]": "1", "/order/@id/x": "1", "/@id": "1", "/order/": "1", "": "1",
          #|  "/order/text()": "1", "/a/b c": "1", "/a/@xmlns": "urn:a" } } }
        ),
      ),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/xml/order~1id: is not a valid XML path: position 0: a path starts with /
      #|a.json: /stubs/0/request/body/xml/~1order~1~1id: is not a valid XML path: position 6: // (descendants) is not supported in smock's XML paths
      #|a.json: /stubs/0/request/body/xml/~1order~1*: is not a valid XML path: position 7: wildcard * is not supported in smock's XML paths
      #|a.json: /stubs/0/request/body/xml/~1soap:Envelope: is not a valid XML path: position 1: prefix soap: is not supported in smock's XML paths; name the local name only
      #|a.json: /stubs/0/request/body/xml/~1order~1item[1]: is not a valid XML path: position 11: predicate or index [...] is not supported in smock's XML paths
      #|a.json: /stubs/0/request/body/xml/~1order~1@id~1x: is not a valid XML path: position 10: an attribute step must come last
      #|a.json: /stubs/0/request/body/xml/~1@id: is not a valid XML path: position 1: a path names the root element first
      #|a.json: /stubs/0/request/body/xml/~1order~1: is not a valid XML path: position 7: expected an element name
      #|a.json: /stubs/0/request/body/xml/: is not a valid XML path: position 0: a path starts with /
      #|a.json: /stubs/0/request/body/xml/~1order~1text(): is not a valid XML path: position 7: function text() is not supported in smock's XML paths
      #|a.json: /stubs/0/request/body/xml/~1a~1b c: is not a valid XML path: position 4: expected / or the end of the path
      #|a.json: /stubs/0/request/body/xml/~1a~1@xmlns: is not a valid XML path: position 4: @xmlns is a namespace declaration, which smock's XML paths never select
    ),
  )
}

///|
test "an xml condition's values are read as query values are, and the body takes exactly one kind of condition" {
  inspect(
    stub_problems([
      stub_with(
        "values",
        (
          #|"request": { "body": { "xml": {
          #|  "/a": 1, "/b": { "$nto": "1" }, "/c": { "$includes": "1" }, "/d": { "pattern": "(" },
          #|  "/e": { "$exists": "yes" }, "/f": { "$not": "1", "pattern": "1" }, "/g//h": { "$exists": 1 } } } }
        ),
      ),
      stub_with(
        "not-an-object", "\"request\": { \"body\": { \"xml\": [\"/a\"] } }",
      ),
      stub_with(
        "two-kinds", "\"request\": { \"body\": { \"xml\": { \"/a\": \"1\" }, \"json\": {} } }",
      ),
      stub_with("no-kind", "\"request\": { \"body\": { \"xmll\": {} } }"),
    ]),
    content=(
      #|a.json: /stubs/0/request/body/xml/~1a: must be a string or an object
      #|a.json: /stubs/0/request/body/xml/~1b/$nto: is not an operator: the operators here are $not, $exists; write $$nto for a literal key that starts with $
      #|a.json: /stubs/0/request/body/xml/~1c/$includes: is allowed only in a json condition
      #|a.json: /stubs/0/request/body/xml/~1d/pattern: is not a valid pattern: position 0: missing closing )
      #|a.json: /stubs/0/request/body/xml/~1e/$exists: must be true or false
      #|a.json: /stubs/0/request/body/xml/~1f/pattern: is not allowed beside "$not": an operator is the only key of its object
      #|a.json: /stubs/0/request/body/xml/~1g~1~1h: is not a valid XML path: position 2: // (descendants) is not supported in smock's XML paths
      #|a.json: /stubs/0/request/body/xml/~1g~1~1h/$exists: must be true or false
      #|a.json: /stubs/1/request/body/xml: must be an object
      #|a.json: /stubs/2/request/body: has "json" and "xml"; give only one of "json", "pattern", "form" or "xml"
      #|a.json: /stubs/3/request/body/xmll: is not a known field
      #|a.json: /stubs/3/request/body: needs "json", "pattern", "form" or "xml"
    ),
  )
}

///|
test "an xml condition shadows a later one that has each of its paths with the same condition, in any order" {
  inspect(
    verdicts([
      (
        "{ \"body\": { \"xml\": { \"/a\": \"1\" } } }", "{ \"body\": { \"xml\": { \"/b\": \"2\", \"/a\": \"1\" } } }",
      ),
      (
        "{ \"body\": { \"xml\": { \"/a\": \"1\", \"/a/@b\": { \"$not\": \"2\" } } } }",
        "{ \"path\": \"/x\", \"body\": { \"xml\": { \"/a/@b\": { \"$not\": \"2\" }, \"/a\": \"1\" } } }",
      ),
      (
        "{ \"path\": \"/x\" }", "{ \"path\": \"/x\", \"body\": { \"xml\": { \"/a\": \"1\" } } }",
      ),
      (
        "{ \"body\": { \"xml\": { \"/a\": \"1\", \"/b\": \"2\" } } }", "{ \"body\": { \"xml\": { \"/a\": \"1\" } } }",
      ),
      (
        "{ \"body\": { \"xml\": { \"/a\": \"1\" } } }", "{ \"body\": { \"xml\": { \"/a\": { \"pattern\": \"1\" } } } }",
      ),
      (
        "{ \"body\": { \"xml\": { \"/a/@b\": \"1\" } } }", "{ \"body\": { \"xml\": { \"/a/b\": \"1\" } } }",
      ),
      (
        "{ \"body\": { \"xml\": { \"/a\": { \"$exists\": true } } } }", "{ \"body\": { \"xml\": { \"/a\": { \"$exists\": false } } } }",
      ),
      ("{ \"body\": { \"xml\": { \"/a\": \"1\" } } }", "{ \"path\": \"/x\" }"),
      (
        "{ \"body\": { \"xml\": { \"/a\": \"1\" } } }", "{ \"body\": \"<a>1</a>\" }",
      ),
    ]),
    content=(
      #|t { "body": { "xml": { "/a": "1" } } } / s { "body": { "xml": { "/b": "2", "/a": "1" } } } -> shadowed
      #|t { "body": { "xml": { "/a": "1", "/a/@b": { "$not": "2" } } } } / s { "path": "/x", "body": { "xml": { "/a/@b": { "$not": "2" }, "/a": "1" } } } -> shadowed
      #|t { "path": "/x" } / s { "path": "/x", "body": { "xml": { "/a": "1" } } } -> shadowed
      #|t { "body": { "xml": { "/a": "1", "/b": "2" } } } / s { "body": { "xml": { "/a": "1" } } } -> not reported
      #|t { "body": { "xml": { "/a": "1" } } } / s { "body": { "xml": { "/a": { "pattern": "1" } } } } -> not reported
      #|t { "body": { "xml": { "/a/@b": "1" } } } / s { "body": { "xml": { "/a/b": "1" } } } -> not reported
      #|t { "body": { "xml": { "/a": { "$exists": true } } } } / s { "body": { "xml": { "/a": { "$exists": false } } } } -> not reported
      #|t { "body": { "xml": { "/a": "1" } } } / s { "path": "/x" } -> not reported
      #|t { "body": { "xml": { "/a": "1" } } } / s { "body": "<a>1</a>" } -> not reported
    ),
  )
}
