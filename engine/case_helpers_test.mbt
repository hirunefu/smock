// Seam 1 tests of `uppercase`, `lowercase` and `trim`: the worked example
// of their ticket, and the render errors they give, with the JSON Pointer
// of the field.

///|
/// The worked example: a code in upper case, and a name trimmed of the
/// ideographic space before it and the space after it.
let case_example : (String, String) = (
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
    #|        code: ${uppercase(body.code)}
    #|        name: ${trim(query.name)}
  ),
)

///|
test "worked example: a code in upper case keeps its ß, and a name loses the ideographic space before it and the space after it" {
  let h = harness([case_example])
  inspect(
    response(
      h.send("POST", "/?name=%E3%80%80Ann%20", body="{\"code\":\"straße-ç\"}"),
    ),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: codes; via=default
      #|{"code":"STRAßE-Ç","name":"Ann"}
    ),
  )
}

///|
test "a case or trim helper's bad argument from the request is the 500 template failed, with the JSON Pointer of the field" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "json": { "code": "${uppercase(body.code)}", "name": "${trim(body.name ?? '')}",
      #|            "lang": "${lowercase(query.lang ?? 'EN')}" } }
    ),
  )
  inspect(
    [
      h.body("/?lang=JA", body="{\"code\":\"x\",\"name\":\" Ann \"}"),
      h.body("/", body="{\"code\":null}"),
      h.body("/", body="{\"code\":\"x\",\"name\":[\"Ann\"]}"),
    ].join("\n"),
    content=(
      #|{"code":"X","name":"Ann","lang":"ja"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/code","message":"uppercase(): argument 1 must be a string, a number or a boolean, not null"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/name","message":"trim(): argument 1 must be a string, a number or a boolean, not an array"}
    ),
  )
}
