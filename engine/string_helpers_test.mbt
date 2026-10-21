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
