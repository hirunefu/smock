// Tests of the string helpers through the template package's public
// interface. Lengths count Unicode code points, so emoji and CJK text are
// in every test. They run on native and on wasm-gc, and give the same
// output on both.

///|
/// A request whose body holds text, numbers and the other kinds of JSON
/// values, for the string helpers.
let texts : @template.Input = {
  meth: "GET",
  path: "/",
  query: [("n", "42"), ("six", "six"), ("half", "1.5"), ("big", "1e300")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "cjk": "日本語", "emoji": "👍🏽", "list": [1, "a", null], "none": null,
      #|  "object": { "a": 1 }, "big": 12345678901234567890, "flag": false,
      #|  "first": "Ann", "last": "Lee", "items": ["a", "b"] }
    ),
  ),
}

///|
test "len gives the code-point length of a text, a number or a boolean as its text, or the element count of an array" {
  inspect(
    [
      rendered(
        "${len('abc')} ${len('')} ${len(body.cjk)} ${len(body.emoji)}",
        input=texts,
      ),
      rendered(
        "${len(body.list)} ${len(body.big)} ${len(1.50)} ${len(body.flag)}",
        input=texts,
      ),
      rendered("${len(query.missing) ?? 'none'}", input=texts),
      rendered_json("{ \"n\": \"${len(body.list)}\" }", input=texts),
      rendered("${len(body.none)}", input=texts),
      rendered("${len(body.object)}", input=texts),
      rendered("${len(null)}", input=texts),
      rendered("${len(body.x ?? null)}", input=texts),
      rendered("${len()}", input=texts),
      rendered("${len('a', 'b')}", input=texts),
    ].join("\n"),
    content=(
      #|3 0 3 2
      #|3 20 3 5
      #|none
      #|{"n":3}
      #|error at /response/body: len(): argument 1 must be a string, a number, a boolean or an array, not null
      #|error at /response/body: len(): argument 1 must be a string, a number, a boolean or an array, not an object
      #|problem at /response/body: template: column 7: len(): argument 1 must be a string, a number, a boolean or an array, not null
      #|problem at /response/body: template: column 7: len(): argument 1 must be a string, a number, a boolean or an array, not null
      #|problem at /response/body: template: column 3: len() takes 1 argument, not 0
      #|problem at /response/body: template: column 3: len() takes 1 argument, not 2
    ),
  )
}

///|
test "concat joins 2 to 100 values as text" {
  let hundred = Array::make(100, "'x'").join(", ")
  inspect(
    [
      rendered("${concat(body.first, ' ', body.last)}", input=texts),
      rendered(
        "${concat(body.cjk, body.emoji, 1.50, true, query.n, body.big)}",
        input=texts,
      ),
      rendered("${concat('a', query.missing) ?? 'none'}", input=texts),
      rendered("${len(concat(\{hundred}))}", input=texts),
      rendered_json(
        "{ \"name\": \"${concat(body.first, ' ', body.last)}\" }",
        input=texts,
      ),
      rendered("${concat('a', body.none)}", input=texts),
      rendered("${concat(body.list, 'a')}", input=texts),
      rendered("${concat(query.a)}", input=texts),
      rendered("${concat(\{hundred}, 'y')}", input=texts),
      rendered("${concat(null, 'a')}", input=texts),
    ].join("\n"),
    content=(
      #|Ann Lee
      #|日本語👍🏽1.5true4212345678901234567890
      #|none
      #|100
      #|{"name":"Ann Lee"}
      #|error at /response/body: concat(): argument 2 must be a string, a number or a boolean, not null
      #|error at /response/body: concat(): argument 1 must be a string, a number or a boolean, not an array
      #|problem at /response/body: template: column 3: concat() takes 2 to 100 arguments, not 1
      #|problem at /response/body: template: column 3: concat() takes 2 to 100 arguments, not 101
      #|problem at /response/body: template: column 10: concat(): argument 1 must be a string, a number or a boolean, not null
    ),
  )
}
