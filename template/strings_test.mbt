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
  query: [
    ("n", "42"),
    ("six", "six"),
    ("half", "1.5"),
    ("big", "1e300"),
    ("ids", "a,b,c"),
  ],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "cjk": "日本語", "emoji": "👍🏽", "list": [1, "a", null], "none": null,
      #|  "object": { "a": 1 }, "big": 12345678901234567890, "flag": false,
      #|  "first": "Ann", "last": "Lee", "items": ["a", "b"],
      #|  "mixed": [true, false, 1.50, 12345678901234567890, "👍🏽", null],
      #|  "nested": [1, { "a": 1 }], "deep": ["a", ["b"]] }
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

///|
test "substr gives the code points from a position, a negative one counting from the end, and clamps positions out of range" {
  inspect(
    [
      rendered(
        "${substr('東京タワー', 0, 3)} ${substr('東京タワー', 2)} ${substr('東京タワー', -2)} ${substr('東京タワー', -2, 1)}",
        input=texts,
      ),
      rendered(
        "${substr(body.emoji, 0, 1)} ${substr('a👍🏽b', 1, 2)} ${substr('a👍🏽b', -1)}",
        input=texts,
      ),
      rendered(
        "[${substr('abc', 1, -1)}] [${substr('abc', 5)}] [${substr('abc', 3)}] [${substr('abc', -5)}] [${substr('abc', 1, 10)}] [${substr('abc', -5, 2)}]",
        input=texts,
      ),
      rendered(
        "[${substr('abc', 1, 1e300)}] [${substr('abc', query.big)}] [${substr('abc', -1e300)}] [${substr('abc', 0, -1e300)}]",
        input=texts,
      ),
      rendered(
        "${substr(body.big, 0, 5)} ${substr(true, 1)} ${substr(1.50, '1')} ${substr(body.cjk, '1', 1.0)}",
        input=texts,
      ),
      rendered("${substr(query.missing, 1) ?? 'none'}", input=texts),
      rendered_json("{ \"short\": \"${substr(body.cjk, 0, 2)}\" }", input=texts),
      rendered("${substr(body.none, 0)}", input=texts),
      rendered("${substr('abc', query.half)}", input=texts),
      rendered("${substr('abc', 0, body.list)}", input=texts),
      rendered("${substr('abc')}", input=texts),
      rendered("${substr('abc', 'x')}", input=texts),
      rendered("${substr(null, 1)}", input=texts),
      rendered("${substr('abc', 0, 1.5)}", input=texts),
    ].join("\n"),
    content=(
      #|東京タ タワー ワー ワ
      #|👍 👍🏽 b
      #|[] [] [] [abc] [bc] [ab]
      #|[bc] [] [abc] []
      #|12345 rue .5 本
      #|none
      #|{"short":"日本"}
      #|error at /response/body: substr(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: substr(): argument 2 must be an integer, or a string that is one, not "1.5"
      #|error at /response/body: substr(): argument 3 must be an integer, or a string that is one, not an array
      #|problem at /response/body: template: column 3: substr() takes 2 or 3 arguments, not 1
      #|problem at /response/body: template: column 17: substr(): argument 2 must be an integer, or a string that is one, not "x"
      #|problem at /response/body: template: column 10: substr(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 20: substr(): argument 3 must be an integer, or a string that is one, not 1.5
    ),
  )
}

///|
test "indexOf gives the code-point index of the first occurrence at or after a position, or -1; includes says whether there is one" {
  inspect(
    [
      rendered(
        "${indexOf('東京タワー', 'ワ')} ${indexOf('a👍🏽b👍🏽', '👍🏽')} ${indexOf('a👍🏽b👍🏽', '👍🏽', 2)} ${indexOf('a👍🏽b👍🏽', 'b')} ${indexOf(body.cjk, '語')}",
        input=texts,
      ),
      rendered(
        "${indexOf('abcabc', 'c', 3)} ${indexOf('abcabc', 'c', 6)} ${indexOf('abcabc', 'x')} ${indexOf('abc', 'abcd')}",
        input=texts,
      ),
      rendered(
        "${indexOf('abc', 'a', -5)} ${indexOf('abc', 'c', 7)} ${indexOf('abc', '')} ${indexOf('abc', '', 3)} ${indexOf('abc', '', 4)} ${indexOf('', '')}",
        input=texts,
      ),
      rendered(
        "${indexOf('abc', 'a', -1e300)} ${indexOf('abc', 'a', 1e300)} ${indexOf(body.big, 90)} ${indexOf(true, 'u', '1')}",
        input=texts,
      ),
      rendered(
        "${includes('東京タワー', 'タワ')} ${includes(body.emoji, '🏽')} ${includes('abc', 'x')} ${includes('abc', '')} ${includes('', '')} ${includes(body.big, 789)}",
        input=texts,
      ),
      rendered(
        "${indexOf(query.missing, 'a') ?? 'none'} ${includes('a', query.missing) ?? 'none'}",
        input=texts,
      ),
      rendered_json(
        "{ \"at\": \"${indexOf(body.cjk, '本')}\", \"has\": \"${includes(body.cjk, '本')}\" }",
        input=texts,
      ),
      rendered("${indexOf(body.list, 'a')}", input=texts),
      rendered("${indexOf('abc', 'a', query.half)}", input=texts),
      rendered("${includes('abc', body.none)}", input=texts),
      rendered("${indexOf('abc')}", input=texts),
      rendered("${indexOf('abc', 'a', 1, 2)}", input=texts),
      rendered("${indexOf('abc', 'a', 'one')}", input=texts),
      rendered("${includes('abc')}", input=texts),
      rendered("${includes('abc', null)}", input=texts),
    ].join("\n"),
    content=(
      #|3 1 4 3 2
      #|5 -1 -1 -1
      #|0 -1 0 3 -1 0
      #|0 -1 8 2
      #|true true false true true true
      #|none none
      #|{"at":1,"has":true}
      #|error at /response/body: indexOf(): argument 1 must be a string, a number or a boolean, not an array
      #|error at /response/body: indexOf(): argument 3 must be an integer, or a string that is one, not "1.5"
      #|error at /response/body: includes(): argument 2 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: indexOf() takes 2 or 3 arguments, not 1
      #|problem at /response/body: template: column 3: indexOf() takes 2 or 3 arguments, not 4
      #|problem at /response/body: template: column 23: indexOf(): argument 3 must be an integer, or a string that is one, not "one"
      #|problem at /response/body: template: column 3: includes() takes 2 arguments, not 1
      #|problem at /response/body: template: column 19: includes(): argument 2 must be a string, a number or a boolean, not null
    ),
  )
}

///|
test "replace and replaceAll replace the first or every occurrence, taking the search and the replacement as literal text" {
  inspect(
    [
      rendered(
        "${replace('a-b-c', '-', '+')} ${replaceAll('a-b-c', '-', '+')} ${replaceAll('aaa', 'aa', 'b')} ${replace('abc', 'x', 'y')}",
        input=texts,
      ),
      rendered(
        "${replace('abc', 'b', '[$&]')} ${replaceAll('abcb', 'b', '$1')} ${replace('abc', 'b', '$$')} ${replaceAll('a.b.c', '.', '$\\'')}",
        input=texts,
      ),
      rendered(
        "[${replace('abc', '', 'x')}] [${replaceAll('abc', '', 'x')}] [${replaceAll('', '', 'x')}] [${replaceAll('abc', 'abc', '')}]",
        input=texts,
      ),
      rendered(
        "${replaceAll('東京タワー東京', '東京', '大阪')} ${replace(body.emoji, '🏽', '🏿')} ${replaceAll(body.cjk, '本', '👍🏽')}",
        input=texts,
      ),
      rendered(
        "${replace(body.big, 0, '')} ${replaceAll(body.big, 0, '')} ${replace(true, 'ue', 1.5)} ${replaceAll(query.n, 4, body.flag)}",
        input=texts,
      ),
      rendered(
        "${replace(query.missing, 'a', 'b') ?? 'none'} ${replaceAll('a', 'a', query.missing) ?? 'none'}",
        input=texts,
      ),
      rendered(
        "${len(replace('a', 'a', padEnd('', 1048576, 'b')))} ${len(replaceAll(padEnd('', 1048576, 'a'), 'a', 'b'))}",
        input=texts,
      ),
      rendered_json(
        "{ \"name\": \"${replaceAll(body.first, 'n', 'N')}\" }",
        input=texts,
      ),
      rendered("${replace(body.none, 'a', 'b')}", input=texts),
      rendered("${replaceAll('a', body.list, 'b')}", input=texts),
      rendered("${replace('a', 'a', body.object)}", input=texts),
      rendered("${replace('ab', 'a', padEnd('', 1048576, 'b'))}", input=texts),
      rendered(
        "${replaceAll(padEnd('', 1048576, 'a'), 'a', 'bb')}",
        input=texts,
      ),
      rendered("${replace('a', 'b')}", input=texts),
      rendered("${replaceAll('a', 'b', 'c', 'd')}", input=texts),
      rendered("${replaceAll('a', null, 'b')}", input=texts),
    ].join("\n"),
    content=(
      #|a+b-c a+b+c ba abc
      #|a[$&]c a$1c$1 a$$c a$'b$'c
      #|[abc] [abc] [] []
      #|大阪タワー大阪 👍🏿 日👍🏽語
      #|1234567891234567890 123456789123456789 tr1.5 false2
      #|none none
      #|1048576 1048576
      #|{"name":"ANN"}
      #|error at /response/body: replace(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: replaceAll(): argument 2 must be a string, a number or a boolean, not an array
      #|error at /response/body: replace(): argument 3 must be a string, a number or a boolean, not an object
      #|error at /response/body: replace(): the result takes more than 1 MiB
      #|error at /response/body: replaceAll(): the result takes more than 1 MiB
      #|problem at /response/body: template: column 3: replace() takes 3 arguments, not 2
      #|problem at /response/body: template: column 3: replaceAll() takes 3 arguments, not 4
      #|problem at /response/body: template: column 19: replaceAll(): argument 2 must be a string, a number or a boolean, not null
    ),
  )
}

///|
test "split gives an array of strings, which a step can read, $each can walk, a structured template can insert whole and json() can write" {
  inspect(
    [
      rendered(
        "${json(split('a,b,c', ','))} ${json(split('a,,b,', ','))} ${json(split('a::b::c', '::'))} ${json(split('abc', 'abc'))} ${json(split('abc', ';'))}",
        input=texts,
      ),
      rendered(
        "${json(split('東京👍🏽', ''))} ${json(split(body.cjk, '本'))} ${json(split('', ','))} ${json(split('', ''))}",
        input=texts,
      ),
      rendered(
        "${json(split(body.big, 0))} ${json(split(1.5, '.'))} ${json(split(true, ''))}",
        input=texts,
      ),
      rendered(
        "${split(query.ids, ',')[1]} ${split(query.ids, ',')[5] ?? 'none'} ${len(split(query.ids, ','))} ${split(query.missing, ',') ?? 'none'}",
        input=texts,
      ),
      rendered(
        "${len(split(padEnd('', 1048572, 'a'), ','))} ${len(split(padEnd('', 524286, '\"'), ','))}",
        input=texts,
      ),
      rendered_json(
        (
          #|{ "ids": { "$each": "split(query.ids, ',')", "as": "id", "do": "${id}!" },
          #|  "all": "${split(query.ids, ',')}", "first": "${split(query.ids, ',')[0]}" }
        ),
        input=texts,
      ),
      rendered("${split(query.ids, ',')}", input=texts),
      rendered("${split(body.none, ',')}", input=texts),
      rendered("${split('a', body.object)}", input=texts),
      rendered("${split(padEnd('', 1048573, 'a'), ',')}", input=texts),
      rendered("${split(padEnd('', 524287, '\"'), ',')}", input=texts),
      rendered("${split(padEnd('', 300000, 'a'), '')}", input=texts),
      rendered("${split('a')}", input=texts),
      rendered("${split('a', null)}", input=texts),
    ].join("\n"),
    content=(
      #|["a","b","c"] ["a","","b",""] ["a","b","c"] ["",""] ["abc"]
      #|["東","京","👍","🏽"] ["日","語"] [""] [""]
      #|["123456789","123456789",""] ["1","5"] ["t","r","u","e"]
      #|b none 3 none
      #|1 1
      #|{"ids":["a!","b!","c!"],"all":["a","b","c"],"first":"a"}
      #|error at /response/body: an object or an array cannot be written as text; write it with json(…)
      #|error at /response/body: split(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: split(): argument 2 must be a string, a number or a boolean, not an object
      #|error at /response/body: split(): the result takes more than 1 MiB
      #|error at /response/body: split(): the result takes more than 1 MiB
      #|error at /response/body: split(): the result takes more than 1 MiB
      #|problem at /response/body: template: column 3: split() takes 2 arguments, not 1
      #|problem at /response/body: template: column 14: split(): argument 2 must be a string, a number or a boolean, not null
    ),
  )
}

///|
test "join writes the elements of an array as text, null as an empty text, with a separator between them" {
  inspect(
    [
      rendered(
        "${join(body.list, '-')} ${join(body.mixed, ',')} [${join(body.items, '')}] ${join(body.items, '日本')} ${join(body.items, 0)}",
        input=texts,
      ),
      rendered(
        "${join(split(query.ids, ','), '+')} [${join(range(1, 0), ',')}] ${join(range(1, 3), ', ')} ${join(body.missing, ',') ?? 'none'}",
        input=texts,
      ),
      rendered(
        "${len(join(split('a,b', ','), padEnd('', 1048574, 'x')))}",
        input=texts,
      ),
      rendered_json("{ \"tags\": \"${join(body.list, '|')}\" }", input=texts),
      rendered("${join(body.nested, ',')}", input=texts),
      rendered("${join(body.deep, ',')}", input=texts),
      rendered("${join(body.first, ',')}", input=texts),
      rendered("${join(body.object, ',')}", input=texts),
      rendered("${join(body.items, body.none)}", input=texts),
      rendered(
        "${join(split('a,b', ','), padEnd('', 1048575, 'x'))}",
        input=texts,
      ),
      rendered("${join(range(1, 1000), padEnd('', 1100, 'x'))}", input=texts),
      rendered("${join('a,b', ',')}", input=texts),
      rendered("${join(null, ',')}", input=texts),
      rendered("${join(body.items ?? 1, ',')}", input=texts),
      rendered("${join(body.items)}", input=texts),
      rendered("${join(body.items, null)}", input=texts),
    ].join("\n"),
    content=(
      #|1-a- true,false,1.5,12345678901234567890,👍🏽, [ab] a日本b a0b
      #|a+b+c [] 1, 2, 3 none
      #|1048576
      #|{"tags":"1|a|"}
      #|error at /response/body: join(): element [1] of argument 1 must be a string, a number, a boolean or null, not an object
      #|error at /response/body: join(): element [1] of argument 1 must be a string, a number, a boolean or null, not an array
      #|error at /response/body: join(): argument 1 must be an array, not "Ann"
      #|error at /response/body: join(): argument 1 must be an array, not an object
      #|error at /response/body: join(): argument 2 must be a string, a number or a boolean, not null
      #|error at /response/body: join(): the result takes more than 1 MiB
      #|error at /response/body: join(): the result takes more than 1 MiB
      #|problem at /response/body: template: column 8: join(): argument 1 must be an array, not "a,b"
      #|problem at /response/body: template: column 8: join(): argument 1 must be an array, not null
      #|problem at /response/body: template: column 8: join(): argument 1 must be an array, not 1
      #|problem at /response/body: template: column 3: join() takes 2 arguments, not 1
      #|problem at /response/body: template: column 20: join(): argument 2 must be a string, a number or a boolean, not null
    ),
  )
}
