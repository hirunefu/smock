// Seam 1 tests of the arithmetic helpers: the worked example of their
// ticket, computed from request values, and the render errors they give,
// with the JSON Pointer of the field.

///|
/// The worked example: a total, the next page, a third and a price with
/// three decimals, from the query and the body.
let arithmetic_example : (String, String) = (
  "cart.yaml",
  (
    #|mocks:
    #|  - name: cart
    #|stubs:
    #|  - id: total
    #|    mock: cart
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        total: ${multiply(body.price, body.qty)}
    #|        next: ${add(query.page ?? 1, 1)}
    #|        third: ${divide(10, 3)}
    #|        price: ${toFixed(body.price, 3)}
  ),
)

///|
test "worked example: a total, the next page, a third and a price, exact in decimal" {
  let h = harness([arithmetic_example])
  inspect(
    [
      response(h.send("POST", "/?page=4", body="{\"price\":19.99,\"qty\":3}")),
      response(h.send("POST", "/", body="{\"price\":\"0.10\",\"qty\":\"3\"}")),
    ].join("\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: cart; via=default
      #|{"total":59.97,"next":5,"third":3.3333333333,"price":19.990}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: cart; via=default
      #|{"total":0.3,"next":2,"third":3.3333333333,"price":0.100}
    ),
  )
}

///|
test "an arithmetic helper's bad value from the request is the 500 template failed, with the JSON Pointer of the field" {
  let h = one_response(
    (
      #|{ "status": 200, "template": true,
      #|  "headers": { "X-Share": "${divide(body.total ?? 1, query.parts ?? 1)}" },
      #|  "json": { "next": "${add(query.page ?? 0, 1)}",
      #|            "left": "${modulo(body.total ?? 0, query.parts ?? 1)}",
      #|            "big": "${multiply(body.total ?? 0, 1000000000)}" } }
    ),
  )
  inspect(
    [
      h.body("/?page=2&parts=4", body="{\"total\":10}"),
      h.body("/?page=two"),
      h.body("/?page=%201"),
      h.body("/?parts=0", body="{\"total\":10}"),
      h.body("/?parts=0.000", body="{\"total\":10}"),
      h.body("/", body="{\"total\":1000000000}"),
      h.body("/", body="{\"total\":1e30}"),
      h.body("/", body="{\"total\":[10]}"),
    ].join("\n"),
    content=(
      #|{"next":3,"left":2,"big":10000000000}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/next","message":"add(): argument 1 must be a number, or a string that is one, not \"two\""}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/next","message":"add(): argument 1 must be a number, or a string that is one, not \" 1\""}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Share","message":"divide(): argument 2, the divisor, is zero"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Share","message":"divide(): argument 2, the divisor, is zero"}
      #|500 {"error":"template failed","stub":"s","at":"/response/json/big","message":"multiply(): the result has more than 18 digits before the point"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Share","message":"divide(): argument 1 must have at most 18 digits before the point and 18 after, not 1e+30"}
      #|500 {"error":"template failed","stub":"s","at":"/response/headers/X-Share","message":"divide(): argument 1 must be a number, or a string that is one, not an array"}
    ),
  )
}
