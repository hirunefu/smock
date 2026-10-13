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

///|
/// A Stub whose `json` template calls every helper, with the seed 42.
let every_helper : String =
  #|{ "status": 200, "template": true,
  #|  "json": { "uuid": "${fake.uuid()}", "int": "${fake.int(-3, 3)}",
  #|    "wide": "${fake.int(-9007199254740991, 9007199254740991)}",
  #|    "decimal": "${fake.decimal(-1, 1, 3)}", "price": "${fake.decimal(90, 110, 2)}",
  #|    "bool": "${fake.bool()}", "pick": "${fake.pick('a', 2, true, null)}",
  #|    "hex": "${fake.hex(20)}", "word": "${fake.word()}", "words": "${fake.words(3)}",
  #|    "first": "${fake.firstName()}", "last": "${fake.lastName()}",
  #|    "name": "${fake.name()}", "email": "${fake.email()}",
  #|    "now": "${now()}", "later": "${now(90)}", "earlier": "${now(-1)}",
  #|    "millis": "${nowMillis()}", "millisLater": "${nowMillis(2)}",
  #|    "number": "${number('12.50')}", "same": "${number(7)}" } }

///|
test "every helper gives its documented form, and a seeded Stub gives the same sequence of responses on every run" {
  let run = () => {
    let h = one_response(every_helper, fault="{ \"seed\": 42 }")
    Array::makei(3, _ => h.body("/")).join("\n")
  }
  let first_run = run()
  inspect(
    first_run,
    content=(
      #|{"uuid":"967d85fe-343d-4cc0-9b49-c024af3b3103","int":2,"wide":-1536172956905732,"decimal":0.301,"price":101.49,"bool":true,"pick":true,"hex":"bb16c726af08237bc9b2","word":"winter","words":"summit cedar cloud","first":"Noah","last":"Stewart","name":"Adrian Patel","email":"ingrid.duncan78@example.com","now":"2026-10-12T14:30:05.123Z","later":"2026-10-12T14:31:35.123Z","earlier":"2026-10-12T14:30:04.123Z","millis":1791815405123,"millisLater":1791815407123,"number":12.5,"same":7}
      #|{"uuid":"bb468c1b-68bb-4082-8d7b-aae65078e215","int":-2,"wide":4962910357813796,"decimal":-0.801,"price":92.23,"bool":true,"pick":true,"hex":"c6e4e874a7024bf54f90","word":"diamond","words":"pepper lantern magnet","first":"Isabel","last":"Suzuki","name":"Emily Holmes","email":"ava.lopez44@example.com","now":"2026-10-12T14:30:05.123Z","later":"2026-10-12T14:31:35.123Z","earlier":"2026-10-12T14:30:04.123Z","millis":1791815405123,"millisLater":1791815407123,"number":12.5,"same":7}
      #|{"uuid":"1354aacd-d385-4b03-a0d1-40e5777918b1","int":-3,"wide":6668624500655258,"decimal":0.176,"price":92.53,"bool":false,"pick":"a","hex":"6182bfff9dc736e67954","word":"satin","words":"castle rocket salmon","first":"Ahmed","last":"Collins","name":"Hannah Wright","email":"emily.peters02@example.com","now":"2026-10-12T14:30:05.123Z","later":"2026-10-12T14:31:35.123Z","earlier":"2026-10-12T14:30:04.123Z","millis":1791815405123,"millisLater":1791815407123,"number":12.5,"same":7}
    ),
  )
  inspect(run() == first_run, content="true")
}

///|
test "a template draws from its own generator: the Stub's source still advances once per matched request, so its Fault decisions do not change" {
  let with_template = harness([
    faults_file([
      (
        #|{ "id": "seeded", "mock": "m", "request": { "path": "/seeded" },
        #|  "response": { "status": 200, "template": true,
        #|    "body": "${fake.uuid()} ${fake.words(100)} ${fake.hex(64)}" },
        #|  "fault": { "delay": { "uniform": { "min": 1, "max": 1000 }, "probability": 0.5 },
        #|    "connection": { "kind": "close", "probability": 0.5 }, "seed": 42 } }
      ),
    ]),
  ])
  // The decisions of seed 42 from its first request on, as a Stub without
  // a template gets them (faults_test.mbt).
  inspect(
    decisions(with_template, "/seeded", 8).join("\n"),
    content=(
      #|delay 0, Close
      #|delay 0
      #|delay 395
      #|delay 572
      #|delay 818
      #|delay 0, Close
      #|delay 594, Close
      #|delay 0
    ),
  )
}

///|
test "every matched request takes exactly one output from the process generator, with or without Faults or a template" {
  let file = faults_file([
    coin_flips("/flips"),
    (
      #|{ "id": "plain", "mock": "m", "request": { "path": "/plain" },
      #|  "response": { "status": 200 } }
    ),
    (
      #|{ "id": "templated", "mock": "m", "request": { "path": "/templated" },
      #|  "response": { "status": 200, "template": true, "body": "${fake.words(50)}" } }
    ),
  ])
  let alone = decisions(harness([file]), "/flips", 6)
  // A request that matches nothing takes no output; a matched one takes
  // one, however many values its template draws.
  let mixed = harness([file])
  let interleaved = [decision(mixed.send("GET", "/flips"))]
  for other in ["/nothing", "/plain", "/templated"] {
    ignore(mixed.send("GET", other))
    interleaved.push(decision(mixed.send("GET", "/flips")))
  }
  inspect(
    "alone: \{alone.join(" | ")}\ninterleaved: \{interleaved.join(" | ")}",
    content=(
      #|alone: delay 913, Close | delay 0 | delay 75 | delay 0 | delay 542 | delay 348, Close
      #|interleaved: delay 913, Close | delay 0 | delay 0 | delay 348, Close
    ),
  )
  inspect(
    interleaved == [alone[0], alone[1], alone[3], alone[5]],
    content="true",
  )
}

///|
test "fake.int and fake.bool draw each value about equally often" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "json": { "$each": "range(1, 1000)", "as": "i",
      #|    "do": ["${fake.int(1, 4)}", "${fake.bool()}"] } }
    ),
  )
  let counts = Map([])
  for _ in 0..<4 {
    guard @json.parse(h.body("/")) is Array(draws) else { fail("not an array") }
    for draw in draws {
      guard draw is Array([n, b]) else { fail("not a pair") }
      for value in [n, b] {
        let key = value.stringify()
        counts[key] = counts.get(key).unwrap_or(0) + 1
      }
    }
  }
  let shares = counts
    .to_array()
    .map(entry => {
      let p = if entry.0 is ("true" | "false") { 0.5 } else { 0.25 }
      "\{entry.0}: \{plausible(entry.1, 4000, p)}"
    })
  shares.sort()
  inspect(
    shares.join("\n"),
    content=(
      #|1: true
      #|2: true
      #|3: true
      #|4: true
      #|true: true
      #|false: true
    ),
  )
}

///|
/// The body of a templated text body `body`, sent with the Content-Type
/// `content_type`, for `GET target` with the request body `request_body`.
fn escaped(
  content_type : String?,
  body : String,
  target : String,
  request_body? : String = "",
) -> String {
  let headers = match content_type {
    Some(value) => "\"headers\": { \"Content-Type\": \"\{value}\" }, "
    None => ""
  }
  one_response(
    "{ \"status\": 200, \"template\": true, \{headers}\"body\": \{Json::string(body).stringify()} }",
  ).body(target, body=request_body)
}

///|
test "a text body escapes inserted values by the media type of its Content-Type; raw(x) is never escaped, and json(x) writes JSON" {
  let n = "?n=%3Ca%20href%3D%27x%27%3E%26%22%5C%0A"
  let json = "{\"name\": \"${query.n}\", \"raw\": \"${raw(query.n)}\", \"json\": ${json(query.n)}, \"body\": ${json(body)}}"
  let markup = "<p title=\"${query.n}\">${raw(query.n)} ${json(query.n)}</p>"
  let request_body = "{\"a\": [1.50, \"<\\\"\"]}"
  inspect(
    [
      escaped(Some("application/json"), json, n, request_body~),
      escaped(
        Some("application/problem+json; charset=utf-8"),
        json,
        n,
        request_body~,
      ),
      escaped(Some("TEXT/HTML; charset=UTF-8"), markup, n),
      escaped(Some("application/xml"), markup, n),
      escaped(Some("text/xml"), markup, n),
      escaped(Some("image/svg+xml"), markup, n),
      escaped(Some("text/plain"), markup, n),
      escaped(Some("application/jsonp"), markup, n),
      escaped(None, markup, n),
    ].join("\n---\n"),
    content=(
      #|{"name": "<a href='x'>&\"\\\n", "raw": "<a href='x'>&"\
      #|", "json": "<a href='x'>&\"\\\n", "body": {"a":[1.5,"<\""]}}
      #|---
      #|{"name": "<a href='x'>&\"\\\n", "raw": "<a href='x'>&"\
      #|", "json": "<a href='x'>&\"\\\n", "body": {"a":[1.5,"<\""]}}
      #|---
      #|<p title="&lt;a href=&#39;x&#39;&gt;&amp;&quot;\
      #|"><a href='x'>&"\
      #| &quot;&lt;a href=&#39;x&#39;&gt;&amp;\&quot;\\\n&quot;</p>
      #|---
      #|<p title="&lt;a href=&#39;x&#39;&gt;&amp;&quot;\
      #|"><a href='x'>&"\
      #| &quot;&lt;a href=&#39;x&#39;&gt;&amp;\&quot;\\\n&quot;</p>
      #|---
      #|<p title="&lt;a href=&#39;x&#39;&gt;&amp;&quot;\
      #|"><a href='x'>&"\
      #| &quot;&lt;a href=&#39;x&#39;&gt;&amp;\&quot;\\\n&quot;</p>
      #|---
      #|<p title="&lt;a href=&#39;x&#39;&gt;&amp;&quot;\
      #|"><a href='x'>&"\
      #| &quot;&lt;a href=&#39;x&#39;&gt;&amp;\&quot;\\\n&quot;</p>
      #|---
      #|<p title="<a href='x'>&"\
      #|"><a href='x'>&"\
      #| "<a href='x'>&\"\\\n"</p>
      #|---
      #|<p title="<a href='x'>&"\
      #|"><a href='x'>&"\
      #| "<a href='x'>&\"\\\n"</p>
      #|---
      #|<p title="<a href='x'>&"\
      #|"><a href='x'>&"\
      #| "<a href='x'>&\"\\\n"</p>
    ),
  )
}

///|
test "in text, numbers are written in their shortest form, and true, false and null as words; an integer beyond 2^53 keeps its digits" {
  let body = "[1.50, 1e3, 2.0, -0, 0.1, 1e21, 12345678901234567890, true, false, null, \"s\"]"
  let text = Array::makei(11, i => "${body[\{i}]}").join(" ")
  inspect(
    escaped(None, text, "/", request_body=body),
    content="1.5 1000 2 0 0.1 1e+21 12345678901234567890 true false null s",
  )
  inspect(
    json_body(
      "{ \"from the request\": \"${body}\", \"static\": [9.90, 1e3, 12345678901234567890] }",
      body~,
    ),
    content=(
      #|{"from the request":[1.5,1000,2,0,0.1,1e+21,12345678901234567890,true,false,null,"s"],"static":[9.9,1000,12345678901234567890]}
    ),
  )
}

///|
test "a templated header value never puts a line break into the head: every control character but tab becomes a space" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "headers": { "X-Echo": "<${query.v}>", "Content-Type": "text/plain" },
      #|  "body": "${query.v}" }
    ),
  )
  inspect(
    response(
      h.send("GET", "/?v=a%0D%0ASet-Cookie:%20x%09tab%00nul%7Fdel", headers=[
        ("Host", "m.example"),
      ]),
    )
    .replace_all(old="\u{7f}", new="<DEL>")
    .escape(),
    content=(
      #|"200\nX-Echo: <a  Set-Cookie: x\ttab nul del>\nContent-Type: text/plain\na\r\nSet-Cookie: x\ttab\u{00}nul<DEL>del"
    ),
  )
}

///|
test "a templated event's data may give several lines, and every control character of its id and event becomes a space" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true, "events": [
      #|  { "delay": 5, "event": "${query.v}", "id": "${query.v}", "data": "${query.v}" } ] }
    ),
  )
  inspect(
    h.body("/?v=a%0Ab%0D%0Ac%09d%00e"),
    content=(
      #|after 5 ms: event "a b  c d e", id "a b  c d e", data "a\nb\r\nc\td\u{00}e"
    ),
  )
}

///|
test "a missing value is a render error unless ?? gives a fallback; in $if it is false, and a loop over an absent query parameter runs zero times" {
  let cases = [
    ("{ \"body\": \"${query.x}\" }", "/"),
    ("{ \"body\": \"${query.x ?? 'fallback'} ${body.note ?? null}\" }", "/"),
    ("{ \"headers\": { \"X-A\": \"${header.x-a}\" } }", "/"),
    ("{ \"json\": { \"a\": [\"${path[3]}\"] } }", "/a/b"),
    (
      "{ \"json\": { \"$each\": \"body.items\", \"as\": \"i\", \"do\": 1 } }", "/",
    ),
    (
      "{ \"json\": { \"$each\": \"body.items ?? range(1, 2)\", \"as\": \"i\", \"do\": \"${i}\" } }",
      "/",
    ),
    ("{ \"json\": { \"$each\": \"query.x\", \"as\": \"i\", \"do\": 1 } }", "/"),
    (
      "{ \"json\": { \"$if\": \"body.missing.deeper\", \"then\": 1, \"else\": 2 } }",
      "/",
    ),
    ("{ \"json\": \"${number(query.n) ?? 0}\" }", "/"),
    (
      "{ \"json\": { \"$each\": \"range(1, number(query.n))\", \"as\": \"i\", \"do\": 1 } }",
      "/",
    ),
    (
      "{ \"events\": [{ \"data\": \"ok\" }, { \"id\": \"${query.id}\", \"data\": \"x\" }] }",
      "/",
    ),
  ]
  inspect(
    cases
    .map(c => {
      one_response("{ \"status\": 200, \"template\": true, \{c.0[1:]}").body(
        c.1,
      )
    })
    .join("\n"),
    content=(
      #|500 {"error":"template failed","stub":"s","at":"/response/body","message":"query.x is missing"}
      #|fallback null
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-A","message":"header.x-a is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/a/0","message":"path[3] is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"body.items is missing"}
      #|[1,2]
      #|[]
      #|2
      #|0
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"query.n is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/events/1/id","message":"query.id is missing"}
    ),
  )
}

///|
test "type errors are render errors: a loop over what is not an array, number() of text that is not a number, raw() of an object, a range bound that is not an integer" {
  let cases = [
    ("{ \"json\": { \"$each\": \"body.n\", \"as\": \"i\", \"do\": 1 } }", "/"),
    ("{ \"json\": { \"$each\": \"path\", \"as\": \"i\", \"do\": 1 } }", "/"),
    ("{ \"json\": \"${number(query.n)}\" }", "/?n=abc"),
    ("{ \"json\": \"${number(query.n)}\" }", "/?n=%201"),
    ("{ \"json\": \"${number(body)}\" }", "/"),
    ("{ \"body\": \"${raw(body)}\" }", "/"),
    ("{ \"json\": \"x${body}\" }", "/"),
    (
      "{ \"json\": { \"$each\": \"range(number(query.n), 3)\", \"as\": \"i\", \"do\": 1 } }",
      "/?n=1.5",
    ),
    (
      "{ \"json\": { \"$each\": \"range(number(query.n), 3)\", \"as\": \"i\", \"do\": 1 } }",
      "/?n=-9007199254740992",
    ),
    ("{ \"body\": \"${now(-9007199254740)}\" }", "/"),
  ]
  inspect(
    cases
    .map(c => {
      one_response("{ \"status\": 200, \"template\": true, \{c.0[1:]}").body(
        c.1,
        body="{\"n\": 1}",
      )
    })
    .join("\n"),
    content=(
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"$each walks an array, not a number"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"$each walks an array, not a string"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json","message":"number(): \"abc\" is not a JSON number"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json","message":"number(): \" 1\" is not a JSON number"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json","message":"number() takes a string or a number, not an object"}
      #|500 {"error":"template failed","stub":"s","at":"/response/body","message":"raw() takes a string, a number, true, false or null, not an object or an array"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json","message":"an object or an array cannot be written as text; give the value alone in its string to keep it"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"range() takes integers from -9007199254740991 to 9007199254740991, not 1.5"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"range() takes integers from -9007199254740991 to 9007199254740991, not -9007199254740992"}
      #|500 {"error":"template failed","stub":"s","at":"/response/body","message":"now(): the time is outside the years 0 to 9999"}
    ),
  )
}

///|
/// The first 200 characters of `s`.
fn at_most_200(s : String) -> String {
  if s.length() > 200 {
    s[:200].to_owned()
  } else {
    s
  }
}

///|
test "bounds from the request are checked when rendering:range gives at most 1000 values, a response runs at most 10000 loop iterations, and a body or the events take at most 1 MiB" {
  let loops = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "json": { "$each": "range(1, number(query.outer))", "as": "i",
      #|    "do": { "$each": "range(1, number(query.inner))", "as": "j", "do": 0 } } }
    ),
  )
  let size = (target : String) => {
    let body = loops.body(target)
    if body.has_prefix("500") {
      body
    } else {
      "\{body.length()} characters"
    }
  }
  let kib = "x".repeat(1100)
  let big = "x".repeat(1024 * 1024)
  inspect(
    [
      size("/?outer=1000&inner=1"),
      size("/?outer=1001&inner=1"),
      size("/?outer=100&inner=99"),
      size("/?outer=100&inner=100"),
      one_response(
        (
          #|{ "status": 200, "template": true,
          #|  "json": { "$each": "range(1, 1000)", "as": "i", "do": "${bodyText}" } }
        ),
      ).body("/", body=kib)
      |> at_most_200,
      one_response(
        (
          #|{ "status": 200, "template": true, "body": "${bodyText}${bodyText}" }
        ),
      ).body("/", body=big)
      |> at_most_200,
      one_response(
        (
          #|{ "status": 200, "template": true,
          #|  "events": [{ "data": "${bodyText}" }, { "id": "${bodyText}", "data": "x" }] }
        ),
      ).body("/", body=big)
      |> at_most_200,
    ].join("\n"),
    content=(
      #|4001 characters
      #|500 {"error":"template failed","stub":"s","at":"/response/json/$each","message":"range(1, 1001) gives 1001 values; range gives at most 1000"}
      #|20001 characters
      #|500 {"error":"template failed","stub":"s","at":"/response/json/do/$each","message":"the loops of one response run at most 10000 iterations"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/do","message":"the rendered body or events take more than 1 MiB"}
      #|500 {"error":"template failed","stub":"s","at":"/response/body","message":"the rendered body or events take more than 1 MiB"}
      #|500 {"error":"template failed","stub":"s","at":"/response/events/1/id","message":"the rendered body or events take more than 1 MiB"}
    ),
  )
}

///|
test "with a render error, a delay Fault still applies first and a connection Fault still replaces the 500; a stream gets the 500 and no events" {
  let delayed = one_response(
    "{ \"status\": 200, \"template\": true, \"body\": \"${query.x}\" }",
    fault="{ \"delay\": { \"fixed\": 250 }, \"connection\": { \"kind\": \"partial\" } }",
  )
  let plan = delayed.send("GET", "/", headers=[("Host", "m.example")]).plan
  inspect(
    "\{plan.status} after \{plan.delay_ms} ms, \{@debug.to_string(plan.fault)}",
    content="500 after 250 ms, Some(Partial)",
  )
  let stream = one_response(
    (
      #|{ "status": 200, "template": true, "headers": { "X-A": "a" },
      #|  "events": [{ "data": "first" }, { "delay": 100, "data": "${query.x}" }] }
    ),
  )
  inspect(
    response(stream.send("GET", "/", headers=[("Host", "m.example")])),
    content=(
      #|500
      #|Content-Type: application/json
      #|{"error":"template failed","stub":"s","at":"/response/events/1/data","message":"query.x is missing"}
    ),
  )
}
