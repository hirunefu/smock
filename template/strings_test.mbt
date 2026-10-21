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

///|
test "padStart and padEnd pad a text to a length in code points, the pad repeated and cut to fit" {
  inspect(
    [
      rendered(
        "${padStart(query.n, 6, '0')} ${padEnd(query.n, 6, '0')} [${padStart('abc', 6)}] [${padEnd('abc', 6)}]",
        input=texts,
      ),
      rendered(
        "${padStart('abc', 10, 'foo')} ${padEnd('abc', 10, 'foo')}",
        input=texts,
      ),
      rendered(
        "${padStart('abc', 2)} ${padStart('abc', 3, '0')} ${padEnd('abc', -1, '0')} ${padStart('abc', 6, '')} ${padEnd('abc', 6, '')}",
        input=texts,
      ),
      rendered(
        "${padStart(body.cjk, 5, body.emoji)} ${padStart(body.cjk, 4, body.emoji)} ${padEnd(body.emoji, 5, '日本')}",
        input=texts,
      ),
      rendered(
        "${padStart(query.n, '6', 0)} ${padStart(query.n, 6.0, 0)} ${padStart(true, 6, 1.5)} ${padEnd(body.big, number('22'), body.flag)}",
        input=texts,
      ),
      rendered("${padStart(query.missing, 6) ?? 'none'}", input=texts),
      rendered_json(
        "{ \"code\": \"${padStart(query.n, 6, '0')}\" }",
        input=texts,
      ),
      rendered("${padStart(query.n, query.half)}", input=texts),
      rendered("${padStart(query.n, query.six)}", input=texts),
      rendered("${padEnd(query.n, body.flag)}", input=texts),
      rendered("${padEnd(query.n, body.list)}", input=texts),
      rendered("${padStart(body.none, 6)}", input=texts),
      rendered("${padStart(query.n, 6, body.object)}", input=texts),
      rendered("${padStart(query.n, query.big)}", input=texts),
      rendered("${padStart(query.n, 'six')}", input=texts),
      rendered("${padStart(query.n, 1.5)}", input=texts),
      rendered("${padEnd(query.n, 6, null)}", input=texts),
      rendered("${padStart(query.n)}", input=texts),
      rendered("${padEnd(query.n, 6, '0', '1')}", input=texts),
    ].join("\n"),
    content=(
      #|000042 420000 [   abc] [abc   ]
      #|foofoofabc abcfoofoof
      #|abc abc abc abc abc
      #|👍🏽日本語 👍日本語 👍🏽日本日
      #|000042 000042 1.true 12345678901234567890fa
      #|none
      #|{"code":"000042"}
      #|error at /response/body: padStart(): argument 2 must be an integer, or a string that is one, not "1.5"
      #|error at /response/body: padStart(): argument 2 must be an integer, or a string that is one, not "six"
      #|error at /response/body: padEnd(): argument 2 must be an integer, or a string that is one, not false
      #|error at /response/body: padEnd(): argument 2 must be an integer, or a string that is one, not an array
      #|error at /response/body: padStart(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: padStart(): argument 3 must be a string, a number or a boolean, not an object
      #|error at /response/body: padStart(): the result takes more than 1 MiB
      #|problem at /response/body: template: column 21: padStart(): argument 2 must be an integer, or a string that is one, not "six"
      #|problem at /response/body: template: column 21: padStart(): argument 2 must be an integer, or a string that is one, not 1.5
      #|problem at /response/body: template: column 22: padEnd(): argument 3 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: padStart() takes 2 or 3 arguments, not 1
      #|problem at /response/body: template: column 3: padEnd() takes 2 or 3 arguments, not 4
    ),
  )
}

///|
test "the string helpers draw nothing, so the fake data around them is the same as without them" {
  let with_strings = rendered_json(
    "{ \"a\": \"${fake.uuid()}\", \"b\": \"${concat(len(body.cjk), padEnd(body.first, 5, '.'))}\", \"c\": \"${fake.word()}\" }",
    input=texts,
  )
  let without = rendered_json(
    "{ \"a\": \"${fake.uuid()}\", \"c\": \"${fake.word()}\" }",
    input=texts,
  )
  inspect(
    "\{with_strings}\n\{without}",
    content=(
      #|{"a":"55c4f5c9-13b3-4f99-8767-9344f82c6c97","b":"3Ann..","c":"signal"}
      #|{"a":"55c4f5c9-13b3-4f99-8767-9344f82c6c97","c":"signal"}
    ),
  )
}
