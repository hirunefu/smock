// Seam 1 tests of the template rules beyond the worked examples: what
// `template` turns on, the grammar, the request fields, structured
// templates, loops, conditionals, helpers, escaping, numbers, missing
// values and the bounds.

///|
/// A harness with one Mock `m` whose only Stub, `s`, has `response`, given
/// as JSON, and answers every request.
fn one_response(
  response : String,
  body_files? : Array[(String, Bytes)] = [],
  fault? : String,
) -> Harness {
  let fault = match fault {
    Some(fault) => ", \"fault\": \{fault}"
    None => ""
  }
  harness(
    [
      (
        "m.json",
        "{ \"mocks\": [{ \"name\": \"m\", \"hosts\": [\"m.example\"] }], \"stubs\": [{ \"id\": \"s\", \"mock\": \"m\", \"response\": \{response}\{fault} }] }",
      ),
    ],
    body_files~,
  )
}

///|
/// The body of the response to `GET target` with `headers` and `body`, as
/// text, after its status when that is not 200.
fn Harness::body(
  self : Harness,
  target : String,
  headers? : Array[(String, String)] = [],
  body? : String = "",
  meth? : String = "GET",
) -> String {
  let outcome = self.send(
    meth,
    target,
    headers=[("Host", "m.example"), ..headers],
    body~,
  )
  let text = match outcome.plan.body {
    Bytes(bytes) => @utf8.decode_lossy(bytes)
    Events(events) => events.iter().map(sse_event).collect().join("\n")
  }
  if outcome.plan.status == 200 {
    text
  } else {
    "\{outcome.plan.status} \{text}"
  }
}

///|
/// The body of the response to `GET target` of a Stub whose response is a
/// `json` template, `json`.
fn json_body(
  json : String,
  target? : String = "/",
  headers? : Array[(String, String)] = [],
  body? : String = "",
) -> String {
  one_response("{ \"status\": 200, \"template\": true, \"json\": \{json} }").body(
    target,
    headers~,
    body~,
  )
}

///|
test "with template off, nothing is parsed or rendered: ${ is plain text and $each a plain key" {
  let h = one_response(
    (
      #|{ "status": 200,
      #|  "headers": { "X-Raw": "${query.a}", "Content-Type": "text/plain; ${x}" },
      #|  "body": "${query.a} $${ ${unknown.helper()} ${" }
    ),
  )
  inspect(
    response(h.send("GET", "/?a=1", headers=[("Host", "m.example")])),
    content=(
      #|200
      #|X-Raw: ${query.a}
      #|Content-Type: text/plain; ${x}
      #|${query.a} $${ ${unknown.helper()} ${
    ),
  )
  inspect(
    one_response(
      (
        #|{ "status": 200, "template": false,
        #|  "json": { "$each": "body.items", "as": "item", "$$x": "${item}",
        #|    "price": 9.90, "big": 12345678901234567890, "e": 1e3 } }
      ),
    ).body("/"),
    content=(
      #|{"$each":"body.items","as":"item","$$x":"${item}","price":9.9,"big":12345678901234567890,"e":1000}
    ),
  )
}

///|
test "a json body is sent as compact JSON with Content-Type application/json, unless the Stub gives a Content-Type" {
  let h = one_response(
    (
      #|{ "status": 200, "json": { "a": [1, 2.50, "x"], "b": { "c": null, "d": true } } }
    ),
  )
  inspect(
    response(h.send("GET", "/", headers=[("Host", "m.example")])),
    content=(
      #|200
      #|Content-Type: application/json
      #|{"a":[1,2.5,"x"],"b":{"c":null,"d":true}}
    ),
  )
  let h = one_response(
    (
      #|{ "status": 200, "headers": { "content-type": "application/problem+json" },
      #|  "json": "text" }
    ),
  )
  inspect(
    response(h.send("GET", "/", headers=[("Host", "m.example")])),
    content=(
      #|200
      #|content-type: application/problem+json
      #|"text"
    ),
  )
}

///|
test "an event's json, templated or not, is sent as one line of compact JSON" {
  let h = one_response(
    (
      #|{ "status": 200, "events": [
      #|  { "json": { "text": "two\nlines", "n": 1.0 } },
      #|  { "event": "e", "json": ["${x}"] } ] }
    ),
  )
  inspect(
    h.body("/"),
    content=(
      #|after 0 ms: event -, id -, data "{\"text\":\"two\\nlines\",\"n\":1}"
      #|after 0 ms: event "e", id -, data "[\"${x}\"]"
    ),
  )
  let h = one_response(
    (
      #|{ "status": 200, "template": true, "events": [
      #|  { "json": { "text": "${query.t}", "n": "${number(query.n)}" } } ] }
    ),
  )
  inspect(
    h.body("/?t=two%0Alines&n=2.50"),
    content=(
      #|after 0 ms: event -, id -, data "{\"text\":\"two\\nlines\",\"n\":2.5}"
    ),
  )
}

///|
test "in a text template, ${ } inserts a value, $${ writes ${, and a $ before anything else is text" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "body": "a $b $${c} $$d ${ query.x } $ ${'it\\'s'}${\"q\\\"\"}${'\\'\\\\'} ${1.50} ${-2e1} ${true} ${false} ${null} ${query.none ?? query.x ?? 'z'}$" }
    ),
  )
  inspect(
    h.body("/?x=X"),
    content=(
      #|a $b ${c} $$d X $ it'sq"'\ 1.5 -20 true false null X$
    ),
  )
}

///|
test "templates read the method, the decoded path and its segments, the query, the headers and the body" {
  let fields = json_body(
    (
      #|{ "method": "${method}", "path": "${path}", "p0": "${path[0]}",
      #|  "p2": "${path[2]}", "past": "${path[9] ?? 'none'}",
      #|  "tag": "${query.tag}", "odd": "${query['naïve name']}",
      #|  "trace": "${header.x-trace}", "TRACE": "${header.X-TRACE}",
      #|  "ab": "${body.a.b}", "first": "${body.items[0]}", "dotted": "${body['odd.key']}",
      #|  "text": "${bodyText}" }
    ),
    target="/files/a%2Fb/caf%C3%A9?tag=one&tag=two&na%C3%AFve+name=Zo%C3%AB",
    headers=[("X-Trace", "t1"), ("x-trace", "t2, t3")],
    body="{\"a\": {\"b\": \"x\"}, \"items\": [1, 2], \"odd.key\": true}",
  )
  inspect(
    fields,
    content=(
      #|{"method":"GET","path":"/files/a/b/café","p0":"files","p2":"b","past":"none","tag":"one","odd":"Zoë","trace":"t1","TRACE":"t1","ab":"x","first":1,"dotted":true,"text":"{\"a\": {\"b\": \"x\"}, \"items\": [1, 2], \"odd.key\": true}"}
    ),
  )
}

///|
test "body is missing when the request body is not JSON, and bodyText has U+FFFD for bytes that are not UTF-8" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "body": "${body ?? 'not JSON'} ${body.a ?? 'no a'} ${bodyText}" }
    ),
  )
  let outcome = h.engine.handle(
    {
      meth: "POST",
      target: "/",
      version: "HTTP/1.1",
      headers: [("Host", "m.example")],
      body: b"x\xff\xfey",
    },
    session=None,
    now=h.now,
    rand=h.rand,
  )
  inspect(
    response(outcome),
    content=(
      #|200
      #|not JSON no a x��y
    ),
  )
  inspect(h.body("/", body="7"), content="7 no a 7")
  // An array cannot be written as text.
  inspect(
    h.body("/", body="[1]"),
    content=(
      #|500 {"error":"template failed","stub":"s","at":"/response/body","message":"an object or an array cannot be written as text; write it with json(…)"}
    ),
  )
}

///|
test "in json, a string that is exactly one ${ } gives the value with its own type, and any other string gives a string" {
  inspect(
    json_body(
      (
        #|{ "object": "${body.a}", "number": "${body.n}", "text": "n=${body.n}",
        #|  "array": "${body.items}", "boolean": "${body.t}", "null": "${body.z}",
        #|  "spaced": " ${body.n}", "literal": 7, "$$each": "a key $each",
        #|  "list": ["${body.n}", { "$if": "body.no", "then": 1 }, 2, "$${body.n}"] }
      ),
      body="{\"a\": {\"b\": \"x\"}, \"n\": 1.50, \"items\": [true, null], \"t\": true, \"z\": null}",
    ),
    content=(
      #|{"object":{"b":"x"},"number":1.5,"text":"n=1.5","array":[true,null],"boolean":true,"null":null,"spaced":" 1.5","literal":7,"$each":"a key $each","list":[1.5,2,"${body.n}"]}
    ),
  )
}

///|
test "a $if without else leaves out its member or element when false, and gives then or else otherwise" {
  inspect(
    json_body(
      (
        #|{ "a": { "$if": "body.no", "then": 1 }, "b": 2,
        #|  "c": { "$if": "body.yes", "then": "yes" },
        #|  "d": { "$if": "body.no", "then": "yes", "else": "no" },
        #|  "e": { "$if": "body.yes", "then": { "$if": "body.no", "then": 1 } },
        #|  "f": [{ "$if": "body.no", "then": 1 }, { "$if": "body.yes", "then": 2 }] }
      ),
      body="{\"yes\": 1}",
    ),
    content=(
      #|{"b":2,"c":"yes","d":"no","f":[2]}
    ),
  )
}

///|
test "$each walks an array, every value of a query parameter or header, or a range; loop.index counts from 0 in the innermost loop" {
  inspect(
    json_body(
      (
        #|{ "items": { "$each": "body.items", "as": "item", "do": "${loop.index}:${item.name}" },
        #|  "tags": { "$each": "query.tag", "as": "t", "do": "${t}" },
        #|  "absent": { "$each": "query.none", "as": "t", "do": "${t}" },
        #|  "headers": { "$each": "header.x-v", "as": "v", "do": "${v}" },
        #|  "range": { "$each": "range(1, 3)", "as": "n", "do": "${n}" },
        #|  "empty": { "$each": "range(3, 1)", "as": "n", "do": "${n}" },
        #|  "count": { "$each": "range(number(query.from), 2)", "as": "n", "do": "${n}" },
        #|  "nested": { "$each": "body.items", "as": "item", "do":
        #|    { "$each": "item.parts", "as": "part",
        #|      "do": "${item.name}.${part}#${loop.index}" } },
        #|  "filtered": { "$each": "body.items", "as": "item",
        #|    "do": { "$if": "item.parts[0]", "then": "${item.name}" } } }
      ),
      target="/?tag=a&tag=b&from=0",
      headers=[("X-V", "1"), ("x-v", "2")],
      body="{\"items\": [{\"name\": \"p\", \"parts\": [\"x\", \"y\"]}, {\"name\": \"q\", \"parts\": []}]}",
    ),
    content=(
      #|{"items":["0:p","1:q"],"tags":["a","b"],"absent":[],"headers":["1","2"],"range":[1,2,3],"empty":[],"count":[0,1,2],"nested":[["p.x#0","p.y#1"],[]],"filtered":["p"]}
    ),
  )
}

///|
test "a condition is true when its value is present and neither null nor false; == and != compare with a literal, and ! negates" {
  let conditions = [
    "body.zero", "body.empty", "body.null", "body.false", "body.missing", "!body.missing",
    "!body.zero", "body.s == 'a'", "body.s == \\\"a\\\"", "body.s != 'b'", "body.one == 1",
    "body.one == 1.0", "body.one == 1e0", "body.s1 == 1", "body.one != '1'", "body.null == null",
    "body.false == false", "body.missing == null", "body.missing != 'a'", "!body.s == 'a'",
    "body.obj == 1", "method == 'GET'",
  ]
  let json = conditions
    .map(cond => "{ \"$if\": \"\{cond}\", \"then\": true, \"else\": false }")
    .join(", ")
  let results = json_body(
    "[\{json}]",
    body="{\"zero\": 0, \"empty\": \"\", \"null\": null, \"false\": false, \"s\": \"a\", \"one\": 1, \"s1\": \"1\", \"obj\": {}}",
  )
  inspect(
    results,
    content=(
      #|[true,true,false,false,false,true,false,true,true,true,true,true,true,false,true,true,true,false,true,false,false,true]
    ),
  )
}
