// Seam 1 tests of list queries: a CRUD Stub's list reads smock's own query
// syntax, with filters by member, `$sort`, `$offset` and `$limit`, and
// counts the bucket's items and those that pass the filters.

///|
test "a list keeps the items whose member meets the filter, and counts the bucket's items and those that pass" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    response(h.shop("GET", "/api/v1/orders?status=pending")),
    content=(
      #|200
      #|Content-Type: application/json
      #|X-Total-Count: 3
      #|X-Filtered-Count: 1
      #|Access-Control-Allow-Origin: *
      #|[{"id":1002,"customerId":7,"status":"pending","total":9.9}]
    ),
  )
}

///|
/// The Mock `kinds`, with the bucket `things`, keyed by `id`, from
/// `things.json`, whose items hold every kind of value in `v`, and the CRUD
/// Stub `things` at `/things`.
fn kinds() -> Harness {
  harness(
    [
      (
        "kinds.yaml",
        (
          #|mocks:
          #|  - name: kinds
          #|data:
          #|  - { mock: kinds, name: things, key: id, jsonFile: things.json }
          #|stubs:
          #|  - id: things
          #|    mock: kinds
          #|    crud: { bucket: things, path: /things }
        ),
      ),
    ],
    body_files=[
      (
        "things.json",
        @utf8.encode(
          (
            #|[
            #|  { "id": 1, "v": "paid" },
            #|  { "id": 2, "v": 12.50 },
            #|  { "id": 3, "v": true },
            #|  { "id": 4, "v": false },
            #|  { "id": 5, "v": null },
            #|  { "id": 6, "v": { "a": 1 } },
            #|  { "id": 7, "v": [1] },
            #|  { "id": 8 },
            #|  { "id": 9, "v": "12.5" },
            #|  { "id": 10, "v": "true" },
            #|  { "id": 11, "v": 12345678901234567890 },
            #|  { "id": 12, "v": "" },
            #|  { "id": 13, "v": "a b" },
            #|  { "id": 14, "a.b": 1, "a": { "b": 1 } },
            #|  { "id": 15, "a": { "b": 1 } },
            #|  { "id": 16, "$v": "x", "$$v": "y", "$": "z" }
            #|]
          ),
        ),
      ),
    ],
  )
}

///|
/// What a list answered: the status and the two counts, then the `id` of
/// each item listed, in order; or the status and the body of any other
/// answer.
fn listed(outcome : @engine.Outcome) -> String {
  let plan = outcome.plan
  guard plan.body is Bytes(body) else { return "\{plan.status} (events)" }
  let text = @utf8.decode_lossy(body)
  if plan.status != 200 {
    return "\{plan.status} \{text}"
  }
  let counts = []
  for header in plan.headers {
    if header.0 is ("X-Total-Count" | "X-Filtered-Count") {
      counts.push(header.1)
    }
  }
  let ids = []
  let parsed = @json.parse(text) catch { _ => Json::null() }
  if parsed is Array(items) {
    for item in items {
      let id = if item is Object(members) && members.get("id") is Some(id) {
        id.stringify()
      } else {
        "?"
      }
      ids.push(id)
    }
  }
  "200 \{counts.join("/")} [\{ids.join(",")}]"
}

///|
/// What `GET <path>?<query>` lists, for each of `queries`, one per line.
fn Harness::lists(
  self : Harness,
  path : String,
  queries : Array[String],
) -> String {
  queries
  .map(query => "?\{query}: \{listed(self.send("GET", "\{path}?\{query}"))}")
  .join("\n")
}

///|
test "a member meets a value as find compares: a string equal to it, a number of equal value, true, false and null by those words; objects, arrays and absent members never" {
  let h = kinds()
  inspect(
    h.lists("/things", [
      "v=paid", "v=12.5", "v=12.50", "v=1.25e1", "v=12.5x", "v=true", "v=false",
      "v=null", "v=12345678901234567890", "v=12345678901234567891", "v=%7B%22a%22:1%7D",
      "v=%5B1%5D", "v=1", "nothing=x", "a.b=1", "a=%7B%22b%22:1%7D",
    ]),
    content=(
      #|?v=paid: 200 16/1 [1]
      #|?v=12.5: 200 16/2 [2,9]
      #|?v=12.50: 200 16/1 [2]
      #|?v=1.25e1: 200 16/1 [2]
      #|?v=12.5x: 200 16/0 []
      #|?v=true: 200 16/2 [3,10]
      #|?v=false: 200 16/1 [4]
      #|?v=null: 200 16/1 [5]
      #|?v=12345678901234567890: 200 16/1 [11]
      #|?v=12345678901234567891: 200 16/0 []
      #|?v=%7B%22a%22:1%7D: 200 16/0 []
      #|?v=%5B1%5D: 200 16/0 []
      #|?v=1: 200 16/0 []
      #|?nothing=x: 200 16/0 []
      #|?a.b=1: 200 16/1 [14]
      #|?a=%7B%22b%22:1%7D: 200 16/0 []
    ),
  )
}

///|
test "every name must hold, and a repeated name holds when any of its values does" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.lists("/api/v1/orders", [
      "customerId=42&status=paid", "customerId=7&status=paid", "status=pending&status=paid",
      "status=pending&customerId=42&status=paid", "status=pending&customerId=42&status=none",
      "customerId=7&customerId=42&id=1003",
    ]),
    content=(
      #|?customerId=42&status=paid: 200 3/2 [1001,1003]
      #|?customerId=7&status=paid: 200 3/0 []
      #|?status=pending&status=paid: 200 3/3 [1001,1002,1003]
      #|?status=pending&customerId=42&status=paid: 200 3/2 [1001,1003]
      #|?status=pending&customerId=42&status=none: 200 3/0 []
      #|?customerId=7&customerId=42&id=1003: 200 3/1 [1003]
    ),
  )
}

///|
test "parameters are decoded as query conditions decode them: + and %20 are a space, and a parameter without = has the empty value" {
  let h = kinds()
  inspect(
    h.lists("/things", [
      "v=a+b", "v=a%20b", "%76=a%2Bb", "v=a+b&&", "v", "v=", "v&v=paid", "%76",
    ]),
    content=(
      #|?v=a+b: 200 16/1 [13]
      #|?v=a%20b: 200 16/1 [13]
      #|?%76=a%2Bb: 200 16/0 []
      #|?v=a+b&&: 200 16/1 [13]
      #|?v: 200 16/1 [12]
      #|?v=: 200 16/1 [12]
      #|?v&v=paid: 200 16/2 [1,12]
      #|?%76: 200 16/1 [12]
    ),
  )
}

///|
test "a name that starts with $ is smock's: $$ escapes a member whose name starts with $, and any name but $sort, $offset and $limit is 400 naming the first" {
  let h = kinds()
  inspect(
    h.lists("/things", [
      "$$v=x", "$$$v=y", "$$=z", "$v=x", "$=z", "$top=5", "%24top=5", "$Sort=id",
      "id=16&$top=5&$skip=1",
    ]),
    content=(
      #|?$$v=x: 200 16/1 [16]
      #|?$$$v=y: 200 16/1 [16]
      #|?$$=z: 200 16/1 [16]
      #|?$v=x: 400 {"error":"invalid query parameter","stub":"things","parameter":"$v"}
      #|?$=z: 400 {"error":"invalid query parameter","stub":"things","parameter":"$"}
      #|?$top=5: 400 {"error":"invalid query parameter","stub":"things","parameter":"$top"}
      #|?%24top=5: 400 {"error":"invalid query parameter","stub":"things","parameter":"$top"}
      #|?$Sort=id: 400 {"error":"invalid query parameter","stub":"things","parameter":"$Sort"}
      #|?id=16&$top=5&$skip=1: 400 {"error":"invalid query parameter","stub":"things","parameter":"$top"}
    ),
  )
}

///|
test "a 400 to a list query is the CRUD Stub's own matched answer, with its crud.headers, and writes nothing" {
  let h = harness(crud_shop(), body_files=data_body_files)
  let outcome = h.shop("GET", "/api/v1/orders?$top=5", session="s")
  inspect(
    "\{response(outcome)}\n\{answered(outcome)}\nstate bytes: \{h.engine.state_stats().bytes}",
    content=(
      #|400
      #|Content-Type: application/json
      #|Access-Control-Allow-Origin: *
      #|{"error":"invalid query parameter","stub":"orders","parameter":"$top"}
      #|{"stub":"orders","stubSource":"file","status":400,"responseIndex":null,"crud":{"op":"list","key":null},"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":null}
      #|state bytes: 0
    ),
  )
}

///|
test "$offset skips that many items and $limit keeps at most that many, after the filters, which X-Filtered-Count counts; numbers too large to hold count as the largest" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.lists("/api/v1/orders", [
      "$offset=0", "$offset=1", "$offset=01", "$offset=3", "$offset=4", "$limit=1",
      "$limit=3", "$limit=99", "$offset=1&$limit=1", "$limit=1&$offset=1", "$offset=99999999999999999999999",
      "$limit=99999999999999999999999", "$offset=2&$limit=99999999999999999999999",
      "customerId=42&$offset=1", "$offset=1&customerId=42&$limit=1", "status=none&$offset=0",
    ]),
    content=(
      #|?$offset=0: 200 3/3 [1001,1002,1003]
      #|?$offset=1: 200 3/3 [1002,1003]
      #|?$offset=01: 200 3/3 [1002,1003]
      #|?$offset=3: 200 3/3 []
      #|?$offset=4: 200 3/3 []
      #|?$limit=1: 200 3/3 [1001]
      #|?$limit=3: 200 3/3 [1001,1002,1003]
      #|?$limit=99: 200 3/3 [1001,1002,1003]
      #|?$offset=1&$limit=1: 200 3/3 [1002]
      #|?$limit=1&$offset=1: 200 3/3 [1002]
      #|?$offset=99999999999999999999999: 200 3/3 []
      #|?$limit=99999999999999999999999: 200 3/3 [1001,1002,1003]
      #|?$offset=2&$limit=99999999999999999999999: 200 3/3 [1003]
      #|?customerId=42&$offset=1: 200 3/2 [1003]
      #|?$offset=1&customerId=42&$limit=1: 200 3/2 [1003]
      #|?status=none&$offset=0: 200 3/0 []
    ),
  )
}

///|
test "$offset and $limit are decimal digits, $offset from 0 and $limit from 1, each given once; anything else is 400" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.lists("/api/v1/orders", [
      "$offset=", "$offset", "$offset=-1", "$offset=%2B1", "$offset=+1", "$offset=1.0",
      "$offset=1e2", "$offset=a", "$offset=%EF%BC%91", "$limit=0", "$limit=00", "$limit=",
      "$limit=-1", "$offset=1&$offset=1", "$limit=2&$offset=1&$limit=2", "$limit=x&$offset=x",
    ]),
    content=(
      #|?$offset=: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=-1: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=%2B1: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=+1: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=1.0: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=1e2: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=a: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$offset=%EF%BC%91: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$limit=0: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
      #|?$limit=00: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
      #|?$limit=: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
      #|?$limit=-1: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
      #|?$offset=1&$offset=1: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$offset"}
      #|?$limit=2&$offset=1&$limit=2: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
      #|?$limit=x&$offset=x: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$limit"}
    ),
  )
}

///|
/// The Mock `mixed`, with the bucket `mixed`, keyed by `id`, from
/// `mixed.json`, whose items hold values of every type in `v`, and the
/// CRUD Stub `mixed` at `/mixed`.
fn mixed() -> Harness {
  harness(
    [
      (
        "mixed.yaml",
        (
          #|mocks:
          #|  - name: mixed
          #|data:
          #|  - { mock: mixed, name: mixed, key: id, jsonFile: mixed.json }
          #|stubs:
          #|  - id: mixed
          #|    mock: mixed
          #|    crud: { bucket: mixed, path: /mixed }
        ),
      ),
    ],
    body_files=[
      (
        "mixed.json",
        @utf8.encode(
          (
            #|[
            #|  { "id": 1, "v": "b" },
            #|  { "id": 2, "v": 10 },
            #|  { "id": 3, "v": null },
            #|  { "id": 4, "v": true },
            #|  { "id": 5, "v": {} },
            #|  { "id": 6, "v": false },
            #|  { "id": 7, "v": "B" },
            #|  { "id": 8, "v": 9.5 },
            #|  { "id": 9 },
            #|  { "id": 10, "v": "a" },
            #|  { "id": 11, "v": [1] },
            #|  { "id": 12, "v": -3 },
            #|  { "id": 13, "v": "｡" },
            #|  { "id": 14, "v": "😀" },
            #|  { "id": 15, "v": 12345678901234567891 },
            #|  { "id": 16, "v": 12345678901234567890 },
            #|  { "id": 17, "v": 1e400 },
            #|  { "id": 18, "v": "" },
            #|  { "id": 19, "v": 10.0 },
            #|  { "id": 20, "v": "ab" },
            #|  { "id": 21, "v": -1e400 }
            #|]
          ),
        ),
      ),
    ],
  )
}

///|
test "$sort orders by type first, null, false, true, numbers by value and strings by code point, and -$sort reverses that; absent members, objects and arrays go last either way, in the bucket's order" {
  let h = mixed()
  inspect(
    h.lists("/mixed", ["$sort=v", "$sort=-v"]),
    content=(
      #|?$sort=v: 200 21/21 [3,6,4,21,12,8,2,19,16,15,17,18,7,10,20,1,13,14,5,9,11]
      #|?$sort=-v: 200 21/21 [14,13,1,20,10,7,18,17,15,16,2,19,8,12,21,4,6,3,5,9,11]
    ),
  )
}

///|
test "$sort=a,-b sorts by each member in turn; ties keep the bucket's order, and items whose member is absent, an object or an array tie, so the next key decides" {
  let orders = harness(crud_shop(), body_files=data_body_files)
  inspect(
    [
      orders.lists("/api/v1/orders", [
        "$sort=customerId", "$sort=-customerId", "$sort=customerId,-total", "$sort=-customerId,total",
        "$sort=status", "$sort=status,-id", "$sort=total,customerId", "$sort=nothing",
        "$sort=-nothing", "$sort=nothing,-id",
      ]),
      mixed().lists("/mixed", [
        "$sort=v,-id&$offset=18", "$sort=-v,-id&$offset=18",
      ]),
    ].join("\n"),
    content=(
      #|?$sort=customerId: 200 3/3 [1002,1001,1003]
      #|?$sort=-customerId: 200 3/3 [1001,1003,1002]
      #|?$sort=customerId,-total: 200 3/3 [1002,1001,1003]
      #|?$sort=-customerId,total: 200 3/3 [1003,1001,1002]
      #|?$sort=status: 200 3/3 [1001,1003,1002]
      #|?$sort=status,-id: 200 3/3 [1003,1001,1002]
      #|?$sort=total,customerId: 200 3/3 [1003,1002,1001]
      #|?$sort=nothing: 200 3/3 [1001,1002,1003]
      #|?$sort=-nothing: 200 3/3 [1001,1002,1003]
      #|?$sort=nothing,-id: 200 3/3 [1003,1002,1001]
      #|?$sort=v,-id&$offset=18: 200 21/21 [11,9,5]
      #|?$sort=-v,-id&$offset=18: 200 21/21 [11,9,5]
    ),
  )
}

///|
test "sort keys are members named literally, so $$ does not escape them" {
  let h = kinds()
  inspect(
    h.lists("/things", [
      "$sort=$v&$limit=2", "$sort=%24v&$limit=2", "$sort=$$v&$limit=2", "$sort=a.b&$limit=2",
    ]),
    content=(
      #|?$sort=$v&$limit=2: 200 16/16 [16,1]
      #|?$sort=%24v&$limit=2: 200 16/16 [16,1]
      #|?$sort=$$v&$limit=2: 200 16/16 [16,1]
      #|?$sort=a.b&$limit=2: 200 16/16 [14,1]
    ),
  )
}

///|
test "a $sort with an empty name, a name that starts with -, or given twice is 400" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.lists("/api/v1/orders", [
      "$sort=", "$sort", "$sort=a,,b", "$sort=-", "$sort=a,", "$sort=,a", "$sort=a,-",
      "$sort=--a", "$sort=-a,--b", "$sort=id&$sort=id", "$sort=id&status=paid&$sort=",
    ]),
    content=(
      #|?$sort=: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=a,,b: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=-: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=a,: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=,a: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=a,-: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=--a: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=-a,--b: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=id&$sort=id: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
      #|?$sort=id&status=paid&$sort=: 400 {"error":"invalid query parameter","stub":"orders","parameter":"$sort"}
    ),
  )
}

///|
test "the list applies the filters, then $sort, then $offset and $limit, wherever they stand in the query" {
  let h = harness(crud_shop(), body_files=data_body_files)
  inspect(
    h.lists("/api/v1/orders", [
      "status=pending&$sort=-id&$limit=10", "status=paid&$sort=-id&$limit=1", "$limit=1&$sort=-id&status=paid",
      "$offset=1&$sort=-total", "$sort=-total&customerId=42&$offset=1&$limit=1",
    ]),
    content=(
      #|?status=pending&$sort=-id&$limit=10: 200 3/1 [1002]
      #|?status=paid&$sort=-id&$limit=1: 200 3/2 [1003]
      #|?$limit=1&$sort=-id&status=paid: 200 3/2 [1003]
      #|?$offset=1&$sort=-total: 200 3/3 [1002,1003]
      #|?$sort=-total&customerId=42&$offset=1&$limit=1: 200 3/2 [1003]
    ),
  )
}

///|
test "numbers order by value as json conditions compare them: exactly when a Double cannot hold them, as large integers and numbers beyond a Double's range" {
  let h = harness(
    [
      (
        "numbers.yaml",
        (
          #|mocks:
          #|  - name: numbers
          #|data:
          #|  - { mock: numbers, name: numbers, key: id, jsonFile: numbers.json }
          #|stubs:
          #|  - id: numbers
          #|    mock: numbers
          #|    crud: { bucket: numbers, path: /numbers }
        ),
      ),
    ],
    body_files=[
      (
        "numbers.json",
        @utf8.encode(
          (
            #|[
            #|  { "id": 1, "v": 12345678901234567891 },
            #|  { "id": 2, "v": 12345678901234567890 },
            #|  { "id": 3, "v": -12345678901234567890 },
            #|  { "id": 4, "v": -12345678901234567891 },
            #|  { "id": 5, "v": 1e400 },
            #|  { "id": 6, "v": 2e400 },
            #|  { "id": 7, "v": 10e399 },
            #|  { "id": 8, "v": -1e400 },
            #|  { "id": 9, "v": -2E+400 },
            #|  { "id": 10, "v": 9007199254740993 },
            #|  { "id": 11, "v": 9007199254740992 },
            #|  { "id": 12, "v": 0 },
            #|  { "id": 13, "v": -0.0 },
            #|  { "id": 14, "v": 0.5 },
            #|  { "id": 15, "v": 1.5e400 },
            #|  { "id": 16, "v": 1e9999999999999999999 },
            #|  { "id": 17, "v": 123456789012345678901234567890 },
            #|  { "id": 18, "v": 0.0001e404 }
            #|]
          ),
        ),
      ),
    ],
  )
  inspect(
    h.lists("/numbers", ["$sort=v", "$sort=-v"]),
    content=(
      #|?$sort=v: 200 18/18 [9,8,4,3,12,13,14,11,10,2,1,17,5,7,18,15,6,16]
      #|?$sort=-v: 200 18/18 [16,6,15,5,7,18,17,1,2,10,11,14,12,13,3,4,8,9]
    ),
  )
}

///|
test "a client's own parameters are filters too, so its list is [] with X-Filtered-Count: 0, and an ordinary Stub before the CRUD Stub can answer such lists from data.NAME" {
  let alone = harness(crud_shop(), body_files=data_body_files)
  let with_stub = harness(
    [
      (
        "pages.yaml",
        (
          #|stubs:
          #|  - id: orders-by-page
          #|    mock: shop
          #|    request:
          #|      method: GET
          #|      path: /api/v1/orders
          #|      query: { page: { $exists: true } }
          #|    response:
          #|      status: 200
          #|      template: true
          #|      json: "${data.orders}"
        ),
      ),
      ..crud_shop(),
    ],
    body_files=data_body_files,
  )
  inspect(
    [
      response(alone.shop("GET", "/api/v1/orders?page=1&_=1791815405123")),
      response(with_stub.shop("GET", "/api/v1/orders?page=1")),
      listed(with_stub.shop("GET", "/api/v1/orders?status=paid")),
    ].join("\n---\n"),
    content=(
      #|200
      #|Content-Type: application/json
      #|X-Total-Count: 3
      #|X-Filtered-Count: 0
      #|Access-Control-Allow-Origin: *
      #|[]
      #|---
      #|200
      #|Content-Type: application/json
      #|[{"id":1001,"customerId":42,"status":"paid","total":12.5},{"id":1002,"customerId":7,"status":"pending","total":9.9},{"id":1003,"customerId":42,"status":"paid","total":3}]
      #|---
      #|200 3/2 [1001,1003]
    ),
  )
}
