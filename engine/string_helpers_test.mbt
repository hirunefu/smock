// Seam 1 tests of the string helpers, steps after a call and range bounds
// from expressions: the worked example of their ticket, and the render
// errors they give, with the JSON Pointer of the field.

///|
/// The worked example: a code padded, a name joined, and a loop as long as
/// a list in the body.
let padded_code_example : (String, String) = (
  "codes.yaml",
  (
    #|mocks:
    #|  - name: codes
    #|stubs:
    #|  - id: code
    #|    mock: codes
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        code: ${padStart(query.n, 6, '0')}
    #|        name: ${concat(body.first, ' ', body.last)}
    #|        lines: { $each: "range(1, len(body.items))", as: i, do: "${i}" }
    #|        second: ${range(1, len(body.items))[1] ?? 'none'}
  ),
)

///|
test "worked example: a code padded to six digits, a name joined, and a loop as long as a list" {
  let h = harness([padded_code_example])
  inspect(
    response(
      h.send(
        "POST",
        "/?n=42",
        body="{\"first\":\"Ann\",\"last\":\"Lee\",\"items\":[\"a\",\"b\"]}",
      ),
    ),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: codes; via=default
      #|{"code":"000042","name":"Ann Lee","lines":[1,2],"second":2}
    ),
  )
  inspect(
    response(
      h.send(
        "POST",
        "/?n=1234567",
        body="{\"first\":\"日本\",\"last\":\"👍🏽\",\"items\":[\"a\"]}",
      ),
    ),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: codes; via=default
      #|{"code":"1234567","name":"日本 👍🏽","lines":[1],"second":"none"}
    ),
  )
}

///|
test "a string helper's bad argument or too large result is the 500 template failed, with the JSON Pointer of the field" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "headers": { "X-Code": "${padStart(query.n, query.width ?? 6, '0')}" },
      #|  "json": {
      #|    "name": "${concat(body.first, ' ', body.last)}",
      #|    "size": "${len(body.items ?? '')}",
      #|    "wide": "${padEnd('x', number(query.wide ?? 1))}",
      #|    "lines": { "$each": "range(1, body.count ?? 1)", "as": "n", "do": "${n}" } } }
    ),
  )
  let ok = "{\"first\":\"Ann\",\"last\":\"Lee\"}"
  inspect(
    [
      h.body("/?n=42", body=ok),
      h.body("/?n=42&width=six", body=ok),
      h.body("/?n=42&width=2.5", body=ok),
      h.body("/?n=42", body="{\"first\":null,\"last\":\"Lee\"}"),
      h.body("/?n=42", body="{\"first\":\"Ann\",\"last\":{\"a\":1}}"),
      h.body("/?n=42", body="{\"first\":\"Ann\",\"last\":\"Lee\",\"items\":{}}"),
      h.body("/?n=42&wide=1048577", body=ok),
      h.body(
        "/?n=42",
        body="{\"first\":\"Ann\",\"last\":\"Lee\",\"count\":\"3\"}",
      ),
    ].join("\n"),
    content=(
      #|{"name":"Ann Lee","size":0,"wide":"x","lines":[1]}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Code","message":"padStart(): argument 2 must be an integer, or a string that is one, not \"six\""}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Code","message":"padStart(): argument 2 must be an integer, or a string that is one, not \"2.5\""}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/name","message":"concat(): argument 1 must be a string, a number or a boolean, not null"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/name","message":"concat(): argument 3 must be a string, a number or a boolean, not an object"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/size","message":"len(): argument 1 must be a string, a number, a boolean or an array, not an object"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/wide","message":"padEnd(): the result takes more than 1 MiB"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/lines/$each","message":"range() takes integers from -9007199254740991 to 9007199254740991, not \"3\""}
    ),
  )
}

///|
/// The worked example of #80: a query parameter split and walked with
/// `$each`, an array joined, and a name cut to three code points.
let split_ids_example : (String, String) = (
  "ids.yaml",
  (
    #|mocks:
    #|  - name: ids
    #|stubs:
    #|  - id: ids
    #|    mock: ids
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        ids: { $each: "split(query.ids, ',')", as: id, do: "${id}" }
    #|        first: ${split(query.ids, ',')[0]}
    #|        tags: ${join(body.tags, '|')}
    #|        short: ${substr(body.name, 0, 3)}
  ),
)

///|
test "worked example: a query parameter split and walked with $each, an array joined, and a name cut to three code points" {
  let h = harness([split_ids_example])
  let body = "{\"tags\":[\"x\",null,1],\"name\":\"東京タワー\"}"
  inspect(
    [
      response(h.send("POST", "/?ids=a,b,c", body~)),
      response(
        h.send(
          "POST",
          "/?ids=%E6%9D%B1%E4%BA%AC,,%F0%9F%91%8D%F0%9F%8F%BD",
          body="{\"tags\":[],\"name\":\"ab\"}",
        ),
      ),
      response(h.send("POST", "/?ids=", body~)),
    ].join("\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: ids; via=default
      #|{"ids":["a","b","c"],"first":"a","tags":"x||1","short":"東京タ"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: ids; via=default
      #|{"ids":["東京","","👍🏽"],"first":"東京","tags":"","short":"ab"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: ids; via=default
      #|{"ids":[""],"first":"","tags":"x||1","short":"東京タ"}
    ),
  )
}

///|
test "a bad argument of substr, indexOf, includes, replace, replaceAll, split or join is the 500 template failed, with the JSON Pointer of the field" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "headers": { "X-At": "${indexOf(query.s ?? 'abc', 'b', query.from ?? 0)}" },
      #|  "json": {
      #|    "ids": { "$each": "split(query.ids, ',')", "as": "id", "do": "${id}" },
      #|    "short": "${substr(body.name ?? 'abc', query.from ?? 0, 2)}",
      #|    "has": "${includes(body.name ?? 'abc', 'b')}",
      #|    "fixed": "${replaceAll(body.name ?? 'abc', 'b', body.with ?? 'B')}",
      #|    "tags": "${join(body.tags, '|')}" } }
    ),
  )
  inspect(
    [
      h.body("/?ids=a,b", body="{\"tags\":[\"x\",null,1]}"),
      h.body("/?ids=a&from=one", body="{\"tags\":[]}"),
      h.body("/", body="{\"tags\":[]}"),
      h.body("/?ids=a", body="{\"name\":null,\"tags\":[]}"),
      h.body("/?ids=a", body="{\"with\":{\"a\":1},\"tags\":[]}"),
      h.body("/?ids=a", body="{\"tags\":[\"x\",[\"y\"]]}"),
      h.body("/?ids=a", body="{\"tags\":\"x|y\"}"),
    ].join("\n"),
    content=(
      #|{"ids":["a","b"],"short":"ab","has":true,"fixed":"aBc","tags":"x||1"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-At","message":"indexOf(): argument 3 must be an integer, or a string that is one, not \"one\""}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/ids/$each","message":"query.ids is missing"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/short","message":"substr(): argument 1 must be a string, a number or a boolean, not null"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/fixed","message":"replaceAll(): argument 3 must be a string, a number or a boolean, not an object"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/tags","message":"join(): element [1] of argument 1 must be a string, a number, a boolean or null, not an array"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/tags","message":"join(): argument 1 must be an array, not \"x|y\""}
    ),
  )
}
