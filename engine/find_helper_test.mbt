// Seam 1 tests of find(array, member, value): the worked example of its
// ticket, an element of a request body's array, and its render error with
// the JSON Pointer of the field.

///|
/// The worked example: the item of the body whose `sku` is the query's.
let find_item_example : (String, String) = (
  "items.yaml",
  (
    #|mocks:
    #|  - name: shop
    #|stubs:
    #|  - id: pick-item
    #|    mock: shop
    #|    request: { method: POST, path: /items/pick }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json: "${find(body.items, 'sku', query.sku) ?? 'no such item'}"
  ),
)

///|
test "worked example: find answers the element of a request body's array whose member meets the query's value" {
  let h = harness([find_item_example])
  let body =
    #|{"items":[{"sku":7,"qty":3},{"sku":42,"qty":1},{"sku":"42","qty":9}]}
  inspect(
    response(h.send("POST", "/items/pick?sku=42", body~)),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"sku":42,"qty":1}
    ),
  )
  inspect(
    response(h.send("POST", "/items/pick?sku=42.0", body~)),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"sku":42,"qty":1}
    ),
  )
  inspect(
    response(h.send("POST", "/items/pick?sku=5", body~)),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|"no such item"
    ),
  )
  inspect(
    response(h.send("POST", "/items/pick?sku=42", body="{\"items\":{}}")),
    content=(
      #|500
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"error":"template failed","stub":"pick-item","at":"/response/json","message":"find(): argument 1 must be an array, not an object"}
    ),
  )
}
