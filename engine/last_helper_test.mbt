// Seam 1 tests of last(array): the last message of a request body's
// conversation, its render error with the JSON Pointer of the field, and
// the item that a Stub's own `append` just added to a keyed Data bucket,
// its new key included.

///|
/// A Stub that quotes the last message of a Chat Completions request, or a
/// fallback when there is none.
let last_message_example : (String, String) = (
  "chat.yaml",
  (
    #|mocks:
    #|  - name: llm
    #|stubs:
    #|  - id: answer
    #|    mock: llm
    #|    request: { method: POST, path: /v1/chat/completions }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      json:
    #|        answer: It is ${last(body.messages).content ?? 'unknown'} in Paris.
    #|        role: ${last(body.messages).role ?? null}
  ),
)

///|
test "last answers the last element of a request body's array, missing for an empty one, and a render error at the field for a value that is not an array" {
  let h = harness([last_message_example])
  let send = (body : String) => {
    response(h.send("POST", "/v1/chat/completions", body~))
  }
  inspect(
    [
      send(
        (
          #|{"messages":[{"role":"user","content":"What is the weather?"},
          #|  {"role":"tool","content":"18 °C, sunny"}]}
        ),
      ),
      send("{\"messages\":[]}"),
      send("{\"messages\":{\"role\":\"user\"}}"),
    ].join("\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: llm; via=default
      #|{"answer":"It is 18 °C, sunny in Paris.","role":"tool"}
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: llm; via=default
      #|{"answer":"It is unknown in Paris.","role":null}
      #|500
      #|Content-Type: application/json
      #|Smock-Mock: llm; via=default
      #|{"error":"template failed","stub":"answer","at":"/response/json/answer","message":"last(): argument 1 must be an array, not an object"}
    ),
  )
}

///|
test "a Stub that appends to a keyed bucket answers the new item, its new key included, with last(data.NAME), in each Session's own copy" {
  let h = orders_harness(
    (
      #|  - id: add-order
      #|    mock: shop
      #|    request: { method: POST, path: /orders }
      #|    dataWrites:
      #|      - { op: append, bucket: orders, value: "${body}" }
      #|    response:
      #|      status: 201
      #|      template: true
      #|      headers: { Location: "/orders/${last(data.orders).id}" }
      #|      json: "${last(data.orders)}"
    ),
  )
  let post = (body : String, session : String) => {
    response(h.send("POST", "/orders", body~, session~))
  }
  inspect(
    [
      post("{\"customerId\":42,\"status\":\"pending\"}", "s"),
      post("{\"customerId\":7}", "s"),
      post("{\"id\":\"a-1\",\"customerId\":9}", "s"),
      post("{\"customerId\":5}", "t"),
    ].join("\n"),
    content=(
      #|201
      #|Location: /orders/1004
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"customerId":42,"status":"pending","id":1004}
      #|201
      #|Location: /orders/1005
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"customerId":7,"id":1005}
      #|201
      #|Location: /orders/a-1
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"id":"a-1","customerId":9}
      #|201
      #|Location: /orders/1004
      #|Content-Type: application/json
      #|Smock-Mock: shop; via=default
      #|{"customerId":5,"id":1004}
    ),
  )
}
