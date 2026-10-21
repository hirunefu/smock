// Tests of the template package through its public interface: parsing,
// rendering for a request, escaping and writing JSON. They run on native
// and on wasm-gc, and give the same output on both.

///|
/// A request for `/users/42?lang=ja&tag=a&tag=b`, with a JSON body.
let request : @template.Input = {
  meth: "POST",
  path: "/users/42",
  query: [("lang", "ja"), ("tag", "a"), ("tag", "b")],
  headers: [("X-Request-Id", "req-7"), ("Content-Type", "application/json")],
  body: b"{\"name\":\"<Ada>\",\"items\":[{\"qty\":2},{\"qty\":0}],\"price\":9.90}",
}

///|
/// 2026-10-13T09:00:00Z, in milliseconds since the Unix epoch.
let nine : Int64 = 1_791_882_000_000L

///|
test "a text template inserts request values, escaped as its kind says" {
  let render = (source : String, kind : @template.TextKind) => {
    match @template.Text::parse(source, pointer="/response/body", kind~) {
      Ok(text) =>
        text.render(@template.Context::new(request, now=nine, draw=1)) catch {
          RenderError(at~, message~) => "error at \{at}: \{message}"
        }
      Err(problem) => "problem at \{problem.pointer}: \{problem.message}"
    }
  }
  inspect(
    [
      render("${method} ${path[1]} ${query.lang} ${body.name}", Body(Plain)),
      render(
        "{\"name\": \"${body.name}\", \"raw\": ${json(body.items)}}",
        Body(JsonString),
      ),
      render("<b>${body.name}</b>${raw(body.name)}", Body(Markup)),
      render("${body.price} $${literal} ${now(1)}", HeaderValue),
      render("${query.missing}", Body(Plain)),
      render("${query.}", Body(Plain)),
    ].join("\n"),
    content=(
      #|POST 42 ja <Ada>
      #|{"name": "<Ada>", "raw": [{"qty":2},{"qty":0}]}
      #|<b>&lt;Ada&gt;</b><Ada>
      #|9.9 ${literal} 2026-10-13T09:00:01.000Z
      #|error at /response/body: query.missing is missing
      #|problem at /response/body: template: column 9: expected a name after .
    ),
  )
}

///|
test "a structured template keeps the types of single values, loops and branches, and draws the same fake data from the same seed on every target" {
  let template = @json.parse(
    (
      #|{ "id": "${path[1]}", "items": "${body.items}",
      #|  "tags": { "$each": "query.tag", "as": "t", "do": "${loop.index}=${t}" },
      #|  "lines": { "$each": "body.items", "as": "item",
      #|    "do": { "$if": "item.qty == 0", "then": "none", "else": "${item.qty}" } },
      #|  "id2": "${fake.uuid()}", "pick": "${fake.pick(1, 'two', null)}",
      #|  "price": "${fake.decimal(1, 2, 3)}", "who": "${fake.email()}" }
    ),
  )
  guard @template.Structured::parse(template, pointer="/response/json")
    is Ok(structured) else {
    fail("the template does not parse")
  }
  let render = (draw : UInt64) => {
    @utf8.decode(
      structured.render(@template.Context::new(request, now=nine, draw~)),
    )
  }
  inspect(
    render(42),
    content=(
      #|{"id":"42","items":[{"qty":2},{"qty":0}],"tags":["0=a","1=b"],"lines":[2,"none"],"id2":"a4ebd216-188f-4ed5-8e96-bd47b1192b9b","pick":"two","price":1.320,"who":"abigail.reed85@example.com"}
    ),
  )
  inspect(render(42) == render(42), content="true")
  inspect(render(42) != render(43), content="true")
}

///|
test "escaping is chosen by the media type of the Content-Type, case-insensitively and without its parameters" {
  inspect(
    [
      None,
      Some("application/json"),
      Some("Application/JSON; charset=utf-8"),
      Some("application/vnd.api+json"),
      Some("text/html;charset=utf-8"),
      Some("text/xml"),
      Some("application/xml"),
      Some("image/svg+xml"),
      Some("text/plain"),
      Some("application/jsonl"),
      Some("json"),
    ]
    .map(content_type => @debug.to_string(@template.escaping_for(content_type)))
    .join(" "),
    content="Plain JsonString JsonString JsonString Markup Markup Markup Markup Plain Plain Plain",
  )
}

///|
test "compact JSON keeps member order and writes each number in its shortest form, or as it kept its text" {
  inspect(
    @template.compact_json(
      @json.parse(
        "{\"b\": [1.50, 1e3, -0, 0.1, 12345678901234567890, 1e400], \"a\": \"\\u0001\\\"\\n\"}",
      ),
    ),
    content=(
      #|{"b":[1.5,1000,0,0.1,12345678901234567890,1e400],"a":"\u0001\"\n"}
    ),
  )
}

///|
test "a number is written in its shortest form, or as the text it kept" {
  let text = (json : Json) => {
    match json {
      Number(n, repr~) => @template.number_text(n, repr)
      _ => "not a number"
    }
  }
  guard @json.parse("[1.50, 1e3, -0, 0.1, 12345678901234567890, 1e400]")
    is Array(numbers) else {
    fail("not an array")
  }
  inspect(
    numbers.map(text).join(" "),
    content="1.5 1000 0 0.1 12345678901234567890 1e400",
  )
  // A helper's output, such as `fake.decimal`, keeps its decimals.
  inspect(text(Json::number(1.5, repr="1.50")), content="1.50")
}

///|
test "indented JSON keeps member order, indents two spaces per level, and writes numbers and strings as compact JSON does" {
  let indented = (json : Json) => {
    @utf8.decode(@template.indented_json_bytes(json))
  }
  inspect(
    indented(
      @json.parse(
        "{\"big\": 12345678901234567890, \"float\": 1.50, \"text\": \"a\\\"b\\\\c\\n\\u0001é/\", \"empty\": {}, \"none\": [], \"list\": [1e3, [], {\"x\": null}, true, false, -0.25]}",
      ),
    ),
    content=(
      #|{
      #|  "big": 12345678901234567890,
      #|  "float": 1.5,
      #|  "text": "a\"b\\c\n\u0001é/",
      #|  "empty": {},
      #|  "none": [],
      #|  "list": [
      #|    1000,
      #|    [],
      #|    {
      #|      "x": null
      #|    },
      #|    true,
      #|    false,
      #|    -0.25
      #|  ]
      #|}
    ),
  )
  // A value that is not a collection, or an empty one, takes one line.
  inspect(
    [Json::number(0.1), Json::string("a\tb"), Json::object({}), Json::array([])]
    .map(indented)
    .join(" "),
    content="0.1 \"a\\tb\" {} []",
  )
}
