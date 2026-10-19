// Seam 1 tests of `xml` body conditions: paths into an XML body, each with
// a value condition. Values are compared by meaning: namespace prefixes,
// indentation and the order of attributes do not matter.

///|
test "an xml condition matches a SOAP request by the value at a path, whatever prefix the client uses and however it indents" {
  let h = stubs([
    (
      #|{ "id": "user-42", "mock": "m",
      #|  "request": { "body": { "xml": { "/Envelope/Body/GetUser/id": "42" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      (
        "POST",
        "/",
        [],
        (
          #|<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          #|  <soap:Body>
          #|    <u:GetUser xmlns:u="urn:users">
          #|      <u:id>42</u:id>
          #|    </u:GetUser>
          #|  </soap:Body>
          #|</soap:Envelope>
        ),
      ),
      (
        "POST",
        "/",
        [],
        "<S:Envelope xmlns:S='http://schemas.xmlsoap.org/soap/envelope/'><S:Body><GetUser xmlns='urn:users'><id>42</id></GetUser></S:Body></S:Envelope>",
      ),
      (
        "POST",
        "/",
        [],
        "<Envelope><Body><GetUser><id>43</id></GetUser></Body></Envelope>",
      ),
      (
        "POST",
        "/",
        [],
        "<Envelope><Body><GetOrder><id>42</id></GetOrder></Body></Envelope>",
      ),
    ]),
    content=(
      #|POST / "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\">\n  <soap:Body>\n    <u:GetUser xmlns:u=\"urn:users\">\n      <u:id>42</u:id>\n    </u:GetUser>\n  </soap:Body>\n</soap:Envelope>" -> user-42
      #|POST / "<S:Envelope xmlns:S='http://schemas.xmlsoap.org/soap/envelope/'><S:Body><GetUser xmlns='urn:users'><id>42</id></GetUser></S:Body></S:Envelope>" -> user-42
      #|POST / "<Envelope><Body><GetUser><id>43</id></GetUser></Body></Envelope>" -> none
      #|POST / "<Envelope><Body><GetOrder><id>42</id></GetOrder></Body></Envelope>" -> none
    ),
  )
}

///|
test "an attribute is matched with a final @name step, with a pattern or an exact value, whatever the order of attributes and their prefixes" {
  let h = stubs([
    (
      #|{ "id": "paid", "mock": "m",
      #|  "request": { "body": { "xml": {
      #|    "/order/@status": { "pattern": "paid|shipped" }, "/order/@currency": "EUR" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "<order status=\"paid\" currency=\"EUR\"/>"),
      ("POST", "/", [], "<order currency='EUR' status='shipped'></order>"),
      (
        "POST",
        "/",
        [],
        "<o:order xmlns:o=\"urn:o\" o:status=\"paid\" currency=\"EUR\"/>",
      ),
      ("POST", "/", [], "<order status=\"draft\" currency=\"EUR\"/>"),
      ("POST", "/", [], "<order status=\"paid\"/>"),
      (
        "POST",
        "/",
        [],
        "<order><status>paid</status><currency>EUR</currency></order>",
      ),
    ]),
    content=(
      #|POST / "<order status=\"paid\" currency=\"EUR\"/>" -> paid
      #|POST / "<order currency='EUR' status='shipped'></order>" -> paid
      #|POST / "<o:order xmlns:o=\"urn:o\" o:status=\"paid\" currency=\"EUR\"/>" -> paid
      #|POST / "<order status=\"draft\" currency=\"EUR\"/>" -> none
      #|POST / "<order status=\"paid\"/>" -> none
      #|POST / "<order><status>paid</status><currency>EUR</currency></order>" -> none
    ),
  )
}

///|
test "an element's value is all the text in it, CDATA and references included, trimmed of whitespace at both ends" {
  let h = stubs([
    (
      #|{ "id": "note", "mock": "m",
      #|  "request": { "body": { "xml": { "/note": "Tom & Jerry <3" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "<note>Tom &amp; Jerry &lt;3</note>"),
      ("POST", "/", [], "<note>\n  Tom &#38; Jerry &#x3C;3\n</note>"),
      ("POST", "/", [], "<note><![CDATA[Tom & Jerry <3]]></note>"),
      (
        "POST",
        "/",
        [],
        "<note>Tom <b>&amp;</b> <!-- c --><i>Jerry</i> &lt;3</note>",
      ),
      ("POST", "/", [], "<note>Tom  &amp; Jerry &lt;3</note>"),
      ("POST", "/", [], "<note>Tom &amp; Jerry &lt;3.</note>"),
    ]),
    content=(
      #|POST / "<note>Tom &amp; Jerry &lt;3</note>" -> note
      #|POST / "<note>\n  Tom &#38; Jerry &#x3C;3\n</note>" -> note
      #|POST / "<note><![CDATA[Tom & Jerry <3]]></note>" -> note
      #|POST / "<note>Tom <b>&amp;</b> <!-- c --><i>Jerry</i> &lt;3</note>" -> note
      #|POST / "<note>Tom  &amp; Jerry &lt;3</note>" -> none
      #|POST / "<note>Tom &amp; Jerry &lt;3.</note>" -> none
    ),
  )
}

///|
test "a path that selects several elements matches when any one of them meets the condition" {
  let h = stubs([
    (
      #|{ "id": "has-b-2", "mock": "m",
      #|  "request": { "body": { "xml": { "/order/item/@sku": "b-2" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "has-pen", "mock": "m",
      #|  "request": { "body": { "xml": { "/order/item/name": { "pattern": "pen.*" } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "<order><item sku='a-1'/><item sku='b-2'/></order>"),
      (
        "POST",
        "/",
        [],
        "<order><item><name>book</name></item><item><name>pencil</name></item></order>",
      ),
      (
        "POST",
        "/",
        [],
        "<order><item sku='a-1'><name>book</name></item></order>",
      ),
      ("POST", "/", [], "<order><box><item sku='b-2'/></box></order>"),
    ]),
    content=(
      #|POST / "<order><item sku='a-1'/><item sku='b-2'/></order>" -> has-b-2
      #|POST / "<order><item><name>book</name></item><item><name>pencil</name></item></order>" -> has-pen
      #|POST / "<order><item sku='a-1'><name>book</name></item></order>" -> none
      #|POST / "<order><box><item sku='b-2'/></box></order>" -> none
    ),
  )
}

///|
test "with no selected node, only $not and $exists false hold; $exists true holds for any selected node, even an empty one" {
  let h = stubs([
    (
      #|{ "id": "not-vip", "mock": "m", "request": { "path": "/not",
      #|    "body": { "xml": { "/order/@tier": { "$not": "vip" } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "no-coupon", "mock": "m", "request": { "path": "/absent",
      #|    "body": { "xml": { "/order/coupon": { "$exists": false } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "coupon", "mock": "m", "request": { "path": "/present",
      #|    "body": { "xml": { "/order/coupon": { "$exists": true } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/not", [], "<order tier='vip'/>"),
      ("POST", "/not", [], "<order tier='basic'/>"),
      ("POST", "/not", [], "<order/>"),
      ("POST", "/not", [], "<other tier='vip'/>"),
      ("POST", "/absent", [], "<order><coupon>X</coupon></order>"),
      ("POST", "/absent", [], "<order><item/></order>"),
      ("POST", "/present", [], "<order><coupon/></order>"),
      ("POST", "/present", [], "<order><item><coupon/></item></order>"),
    ]),
    content=(
      #|POST /not "<order tier='vip'/>" -> none
      #|POST /not "<order tier='basic'/>" -> not-vip
      #|POST /not "<order/>" -> not-vip
      #|POST /not "<other tier='vip'/>" -> not-vip
      #|POST /absent "<order><coupon>X</coupon></order>" -> none
      #|POST /absent "<order><item/></order>" -> no-coupon
      #|POST /present "<order><coupon/></order>" -> coupon
      #|POST /present "<order><item><coupon/></item></order>" -> none
    ),
  )
}

///|
test "a body that is not well-formed XML, or has a DOCTYPE, another encoding or too deep nesting, fails every xml condition, $not and $exists false included" {
  let h = stubs([
    (
      #|{ "id": "not-a", "mock": "m", "request": { "path": "/not",
      #|    "body": { "xml": { "/a": { "$not": "1" } } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "no-b", "mock": "m", "request": { "path": "/absent",
      #|    "body": { "xml": { "/b": { "$exists": false } } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  let nested = depth => "<a>".repeat(depth) + "</a>".repeat(depth)
  let bodies = [
    ("well-formed", "<a>2</a>"),
    ("an end tag that does not match", "<a>2</b>"),
    ("two root elements", "<a>2</a><a>3</a>"),
    ("empty", ""),
    ("JSON", "{\"a\": 2}"),
    ("a DOCTYPE", "<!DOCTYPE a><a>2</a>"),
    (
      "an external entity", "<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a>&x;</a>",
    ),
    (
      "another encoding", "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>2</a>",
    ),
    ("an undeclared entity", "<a>&nbsp;</a>"),
    ("256 deep", nested(256)),
    ("257 deep", nested(257)),
  ]
  let lines = []
  for body in bodies {
    let (name, body) = body
    let winners = ["/not", "/absent"].map(path => {
      matched_id(h.send("POST", path, body~)).unwrap_or("none")
    })
    lines.push("\{name} -> \{winners.join(", ")}")
  }
  inspect(
    lines.join("\n"),
    content=(
      #|well-formed -> not-a, no-b
      #|an end tag that does not match -> none, none
      #|two root elements -> none, none
      #|empty -> none, none
      #|JSON -> none, none
      #|a DOCTYPE -> none, none
      #|an external entity -> none, none
      #|another encoding -> none, none
      #|an undeclared entity -> none, none
      #|256 deep -> not-a, no-b
      #|257 deep -> none, none
    ),
  )
}

///|
test "an empty xml condition holds only for a body that parses as XML, as an empty json condition needs JSON; its failure counts once, as body" {
  let h = stubs([
    (
      #|{ "id": "any-xml", "mock": "m", "request": { "body": { "xml": {} } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [], "<a/>"),
      ("POST", "/", [("Content-Type", "application/json")], "<a>1</a>"),
      ("POST", "/", [], "{}"),
      ("POST", "/", [], "<a><b></a>"),
      ("POST", "/", [], ""),
    ]),
    content=(
      #|POST / "<a/>" -> any-xml
      #|POST / [Content-Type: application/json] "<a>1</a>" -> any-xml
      #|POST / "{}" -> none
      #|POST / "<a><b></a>" -> none
      #|POST / -> none
    ),
  )
  json_inspect(explanation(h, "POST", "/", body="<a><b></a>"), content={
    "stub": "any-xml",
    "stubSource": "file",
    "failed": [
      {
        "condition": "body",
        "expected": { "xml": {} },
        "actual": ["<a><b></a>"],
      },
    ],
  })
}

///|
test "the Content-Type is not consulted: an XML body matches whatever the request says it is" {
  let h = stubs([
    (
      #|{ "id": "a", "mock": "m", "request": { "body": { "xml": { "/a": "1" } } },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    winners(h, [
      ("POST", "/", [("Content-Type", "application/soap+xml")], "<a>1</a>"),
      ("POST", "/", [("Content-Type", "application/json")], "<a>1</a>"),
      ("POST", "/", [], "<a>1</a>"),
      ("POST", "/", [("Content-Type", "text/xml")], "a=1"),
    ]),
    content=(
      #|POST / [Content-Type: application/soap+xml] "<a>1</a>" -> a
      #|POST / [Content-Type: application/json] "<a>1</a>" -> a
      #|POST / "<a>1</a>" -> a
      #|POST / [Content-Type: text/xml] "a=1" -> none
    ),
  )
}

///|
/// A Mock `m` with one Stub, `get-user`, with a header condition and an
/// `xml` condition on a SOAP request, and a Scenario clause that requires a
/// state the Scenario `flow` is not in.
let soap_user : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [{ "id": "get-user", "mock": "m",
  #|    "scenario": { "name": "flow", "requires": "Done" },
  #|    "request": { "method": "POST", "path": "/soap",
  #|      "headers": { "SOAPAction": "GetUser" },
  #|      "body": { "xml": {
  #|        "/Envelope/Body/GetUser/id": "42",
  #|        "/Envelope/Body/GetUser/@lang": { "pattern": "en|ja" },
  #|        "/Envelope/Header/Trace": { "$exists": false },
  #|        "/Envelope/Body/GetUser/role": { "$not": "admin" } } } },
  #|    "response": { "status": 200 } }] }

///|
test "each failed XML path counts once in the Near miss, after the headers and before the Scenario, and the Smock-Near-Miss header escapes it as it escapes a query name" {
  let h = harness([("m.json", soap_user)])
  inspect(
    near_misses(h, [
      (
        "POST",
        "/soap",
        [("SOAPAction", "GetUser")],
        "<Envelope><Body><GetUser lang='en'><id>42</id></GetUser></Body></Envelope>",
      ),
      (
        "POST",
        "/soap",
        [("SOAPAction", "GetOrder")],
        "<Envelope><Header><Trace/></Header><Body><GetUser lang='fr'><id>7</id><role>admin</role></GetUser></Body></Envelope>",
      ),
      ("POST", "/soap", [("SOAPAction", "GetUser")], "<Envelope>"),
    ]),
    content=(
      #|POST /soap [SOAPAction: GetUser] "<Envelope><Body><GetUser lang='en'><id>42</id></GetUser></Body></Envelope>" -> get-user; failed=scenario:flow
      #|POST /soap [SOAPAction: GetOrder] "<Envelope><Header><Trace/></Header><Body><GetUser lang='fr'><id>7</id><role>admin</role></GetUser></Body></Envelope>" -> get-user; failed=header:soapaction,xml:%2FEnvelope%2FBody%2FGetUser%2Fid,xml:%2FEnvelope%2FBody%2FGetUser%2F%40lang,xml:%2FEnvelope%2FHeader%2FTrace,xml:%2FEnvelope%2FBody%2FGetUser%2Frole,scenario:flow
      #|POST /soap [SOAPAction: GetUser] "<Envelope>" -> get-user; failed=xml:%2FEnvelope%2FBody%2FGetUser%2Fid,xml:%2FEnvelope%2FBody%2FGetUser%2F%40lang,xml:%2FEnvelope%2FHeader%2FTrace,xml:%2FEnvelope%2FBody%2FGetUser%2Frole,scenario:flow
    ),
  )
}

///|
test "the Near miss shows a failed XML path's condition as the Stub writes it, with the values the path selects, none when it selects nothing or the body is not XML" {
  let h = harness([("m.json", soap_user)])
  json_inspect(
    explanation(
      h,
      "POST",
      "/soap",
      headers=[("SOAPAction", "GetUser")],
      body=(
        #|<s:Envelope xmlns:s="urn:s">
        #|  <s:Header><Trace>1</Trace></s:Header>
        #|  <s:Body>
        #|    <GetUser lang="fr"><id> 7 </id><role>admin</role></GetUser>
        #|    <GetUser lang="de"><id>8</id><role>user</role></GetUser>
        #|  </s:Body>
        #|</s:Envelope>
      ),
    ),
    content={
      "stub": "get-user",
      "stubSource": "file",
      "failed": [
        {
          "condition": "xml:/Envelope/Body/GetUser/id",
          "expected": "42",
          "actual": ["7", "8"],
        },
        {
          "condition": "xml:/Envelope/Body/GetUser/@lang",
          "expected": { "pattern": "en|ja" },
          "actual": ["fr", "de"],
        },
        {
          "condition": "xml:/Envelope/Header/Trace",
          "expected": { "$exists": false },
          "actual": ["1"],
        },
        {
          "condition": "xml:/Envelope/Body/GetUser/role",
          "expected": { "$not": "admin" },
          "actual": ["admin", "user"],
        },
        {
          "condition": "scenario:flow",
          "expected": "Done",
          "actual": ["Started"],
        },
      ],
    },
  )
  json_inspect(
    explanation(
      h,
      "POST",
      "/soap",
      headers=[("SOAPAction", "GetUser")],
      body="<Envelope><Body><GetUser>",
    ),
    content={
      "stub": "get-user",
      "stubSource": "file",
      "failed": [
        {
          "condition": "xml:/Envelope/Body/GetUser/id",
          "expected": "42",
          "actual": [],
        },
        {
          "condition": "xml:/Envelope/Body/GetUser/@lang",
          "expected": { "pattern": "en|ja" },
          "actual": [],
        },
        {
          "condition": "xml:/Envelope/Header/Trace",
          "expected": { "$exists": false },
          "actual": [],
        },
        {
          "condition": "xml:/Envelope/Body/GetUser/role",
          "expected": { "$not": "admin" },
          "actual": [],
        },
        {
          "condition": "scenario:flow",
          "expected": "Done",
          "actual": ["Started"],
        },
      ],
    },
  )
}

///|
test "the Near miss prefers the Stub with the fewest failed conditions, counting each XML path" {
  let h = stubs([
    (
      #|{ "id": "three-paths", "mock": "m",
      #|  "request": { "body": { "xml": { "/a/b": "1", "/a/c": "2", "/a/d": "3" } } },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "method-and-path", "mock": "m",
      #|  "request": { "method": "PUT", "path": "/x" },
      #|  "response": { "status": 200 } }
    ),
  ])
  inspect(
    near_misses(h, [
      ("POST", "/", [], "<a><b>1</b><c>0</c><d>0</d></a>"),
      ("POST", "/", [], "<a><b>0</b><c>0</c><d>0</d></a>"),
    ]),
    content=(
      #|POST / "<a><b>1</b><c>0</c><d>0</d></a>" -> three-paths; failed=xml:%2Fa%2Fc,xml:%2Fa%2Fd
      #|POST / "<a><b>0</b><c>0</c><d>0</d></a>" -> method-and-path; failed=method,path
    ),
  )
}

///|
test "XML values in a Journal entry's Near miss are kept up to the body limit in total, as the body is cut, and count toward the byte bound" {
  let h = harness(
    [
      (
        "m.json",
        (
          #|{ "mocks": [{ "name": "m" }],
          #|  "stubs": [{ "id": "note", "mock": "m",
          #|    "request": { "body": { "xml": { "/order/@id": "1", "/order/note": "ok" } } },
          #|    "response": { "status": 200 } }] }
        ),
      ),
    ],
    journal=@engine.JournalSettings(body_limit=50),
  )
  let _ = h.record(
    "POST",
    "/",
    body="<order id='2'><note>\{"é".repeat(30)}</note></order>",
  )
  // The id takes 1 byte and 32 more, which leaves 17 bytes of the note:
  // eight é, since a ninth would be split.
  json_inspect(h.answered(None), content={
    "host": null,
    "mock": "m",
    "viaDefault": true,
    "stub": null,
    "nearMiss": {
      "stub": "note",
      "stubSource": "file",
      "failed": [
        { "condition": "xml:/order/@id", "expected": "1", "actual": ["2"] },
        {
          "condition": "xml:/order/note",
          "expected": "ok",
          "actual": ["éééééééé"],
        },
      ],
    },
    "status": 404,
    "fault": null,
  })
  // POST, /, HTTP/1.1, the Mock m, the Near miss's Stub note and its actual
  // values, 2 and eight é, hold 27 code units; the body is cut to 50 bytes,
  // and each of the two values counts 32 bytes more.
  inspect(
    h.stats(),
    content=(
      #|1 entries, 424 bytes, 0 evicted
    ),
  )
}

///|
test "render explains a failed XML path as the Near miss does" {
  let h = harness([("m.json", soap_user)])
  inspect(
    h.failed("get-user", {
      "method": "POST",
      "path": "/soap",
      "headers": { "SOAPAction": "GetUser" },
      "body": "<Envelope><Body><GetUser lang='fr'><id>42</id><role>admin</role></GetUser></Body></Envelope>",
    }),
    content=(
      #|xml:/Envelope/Body/GetUser/@lang: expected {"pattern":"en|ja"}, actual ["fr"]
      #|xml:/Envelope/Body/GetUser/role: expected {"$not":"admin"}, actual ["admin"]
    ),
  )
}

///|
test "an Ephemeral Stub may have an xml condition, and a malformed path is rejected with the message a Definition file gets" {
  let h = harness(shop)
  let added = h.add(
    "users",
    Some("s"),
    (
      #|{ "request": { "method": "POST", "path": "/soap",
      #|    "body": { "xml": { "/Envelope/Body/GetUser/id": "42" } } },
      #|  "response": { "status": 200, "body": "user 42" } }
    ),
  )
  let body = "<s:Envelope xmlns:s='urn:s'><s:Body><GetUser><id>42</id></GetUser></s:Body></s:Envelope>"
  let answers = [
    h.send("POST", "http://users.svc/soap", body~, session="s"),
    h.send("POST", "http://users.svc/soap", body~),
  ].map(outcome => matched_id(outcome).unwrap_or("no Stub"))
  inspect(
    "\{added}: \{answers.join(", ")}\n" +
    h.problems(
      (
        #|{ "request": { "body": { "xml": { "/a//b": "1", "/a/@xmlns": "urn:a", "/c": { "$includes": "1" } } } },
        #|  "response": { "status": 200 } }
      ),
    ),
    content=(
      #|eph-1: eph-1, no Stub
      #|/request/body/xml/~1a~1~1b: is not a valid XML path: position 2: // (descendants) is not supported in smock's XML paths
      #|/request/body/xml/~1a~1@xmlns: is not a valid XML path: position 4: @xmlns is not supported in smock's XML paths: xmlns names namespace declarations, which are not attributes here
      #|/request/body/xml/~1c/$includes: is allowed only in a json condition
    ),
  )
}
