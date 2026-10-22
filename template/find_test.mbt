// Tests of find(array, member, value) through the template package's
// public interface: how a member meets the value, what is missing, and the
// render errors and load errors of its arguments. They run on native and
// on wasm-gc, and give the same output on both.

///|
/// A request whose body holds arrays of objects with members of every kind
/// of JSON value, for find.
let shelves : @template.Input = {
  meth: "POST",
  path: "/orders/1004/pay",
  query: [("sku", "42"), ("name", "pen"), ("price", "12.5")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "items": [
      #|    { "sku": "A-1", "name": "pen", "qty": 1 },
      #|    { "sku": "B-7", "name": "ink", "qty": 0 },
      #|    { "sku": "C-3", "name": "pen", "qty": 5 } ] }
    ),
  ),
}

///|
test "find gives the first element that is an object whose member is a string equal to the value" {
  inspect(
    [
      rendered_json(
        "{ \"item\": \"${find(body.items, 'sku', 'B-7')}\" }",
        input=shelves,
      ),
      rendered_json(
        "{ \"item\": \"${find(body.items, 'name', query.name)}\" }",
        input=shelves,
      ),
    ].join("\n"),
    content=(
      #|{"item":{"sku":"B-7","name":"ink","qty":0}}
      #|{"item":{"sku":"A-1","name":"pen","qty":1}}
    ),
  )
}

///|
/// A request whose body holds orders with numeric and string IDs, and
/// prices written in different ways.
let orders : @template.Input = {
  meth: "POST",
  path: "/orders/1004/pay",
  query: [("id", "1004"), ("price", "12.5")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "orders": [
      #|    { "id": 1003, "price": 9.90 },
      #|    { "id": 1004, "price": 12.50 },
      #|    { "id": "1005", "price": 1.25e1 },
      #|    { "id": 12345678901234567890, "price": 7 },
      #|    { "id": 12345678901234567891, "price": 7.0 } ] }
    ),
  ),
}

///|
test "a number member meets a value whose text is a JSON number of equal value, compared as json conditions compare numbers" {
  inspect(
    [
      rendered("${json(find(body.orders, 'id', 1004))}", input=orders),
      rendered("${json(find(body.orders, 'id', '1004'))}", input=orders),
      rendered("${json(find(body.orders, 'id', path[1]))}", input=orders),
      rendered("${json(find(body.orders, 'id', '1004.0'))}", input=orders),
      rendered("${json(find(body.orders, 'id', '1.004e3'))}", input=orders),
      rendered("${json(find(body.orders, 'price', 12.5))}", input=orders),
      rendered("${json(find(body.orders, 'price', query.price))}", input=orders),
      rendered("${json(find(body.orders, 'price', '12.50'))}", input=orders),
      rendered("${json(find(body.orders, 'price', 9.9))}", input=orders),
      rendered(
        "${json(find(body.orders, 'id', 12345678901234567891))}",
        input=orders,
      ),
      rendered(
        "${json(find(body.orders, 'id', '12345678901234567891'))}",
        input=orders,
      ),
      rendered(
        "${json(find(body.orders, 'id', '12345678901234567890'))}",
        input=orders,
      ),
      rendered("${json(find(body.orders, 'price', '7'))}", input=orders),
      rendered("${json(find(body.orders, 'id', 1005))}", input=orders),
      rendered(
        "${json(find(body.orders, 'id', '1005.0') ?? 'none')}",
        input=orders,
      ),
      rendered(
        "${json(find(body.orders, 'price', '12.5 ') ?? 'none')}",
        input=orders,
      ),
      rendered(
        "${json(find(body.orders, 'price', '+12.5') ?? 'none')}",
        input=orders,
      ),
    ].join("\n"),
    content=(
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1004,"price":12.5}
      #|{"id":1003,"price":9.9}
      #|{"id":12345678901234567891,"price":7}
      #|{"id":12345678901234567891,"price":7}
      #|{"id":12345678901234567890,"price":7}
      #|{"id":12345678901234567890,"price":7}
      #|{"id":"1005","price":12.5}
      #|"none"
      #|"none"
      #|"none"
    ),
  )
}

///|
/// A request whose body holds flags of every kind of JSON value.
let flags : @template.Input = {
  meth: "GET",
  path: "/",
  query: [("on", "true")],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "flags": [
      #|    { "n": 1, "on": "yes" },
      #|    { "n": 2, "on": false },
      #|    { "n": 3, "on": null },
      #|    { "n": 4, "on": true },
      #|    { "n": 5, "on": "null" },
      #|    { "n": 6, "on": "true" } ] }
    ),
  ),
}

///|
test "true, false and null meet the value whose text is that word, and null is a value as text, not an error" {
  inspect(
    [
      rendered("${find(body.flags, 'on', true).n}", input=flags),
      rendered("${find(body.flags, 'on', query.on).n}", input=flags),
      rendered("${find(body.flags, 'on', false).n}", input=flags),
      rendered("${find(body.flags, 'on', 'false').n}", input=flags),
      rendered("${find(body.flags, 'on', null).n}", input=flags),
      rendered("${find(body.flags, 'on', 'null').n}", input=flags),
      rendered("${find(body.flags, 'on', body.missing ?? null).n}", input=flags),
      rendered("${find(body.flags, 'on', 'True').n ?? 'none'}", input=flags),
      rendered("${find(body.flags, 'on', 'yes').n}", input=flags),
    ].join("\n"),
    content=(
      #|4
      #|4
      #|2
      #|2
      #|3
      #|3
      #|3
      #|none
      #|1
    ),
  )
}

///|
test "elements that are not objects, absent members, and members that are objects or arrays never meet the value" {
  let input : @template.Input = {
    ..flags,
    body: @utf8.encode(
      (
        #|{ "mixed": [ "a", 1, null, ["a"], { "k": { "a": 1 } }, { "k": ["a"] },
        #|    { "other": "a" }, { "k": "a", "n": 8 } ],
        #|  "empty": [] }
      ),
    ),
  }
  inspect(
    [
      rendered("${find(body.mixed, 'k', 'a').n}", input~),
      rendered("${find(body.mixed, 'k', null) ?? 'absent is not null'}", input~),
      rendered("${json(find(body.mixed, 'k', '{\"a\":1}') ?? 'none')}", input~),
      rendered("${json(find(body.mixed, 'k', '[\"a\"]') ?? 'none')}", input~),
      rendered("${json(find(body.mixed, '0', 'a') ?? 'none')}", input~),
      rendered("${json(find(body.empty, 'k', 'a') ?? 'none')}", input~),
    ].join("\n"),
    content=(
      #|8
      #|absent is not null
      #|"none"
      #|"none"
      #|"none"
      #|"none"
    ),
  )
}

///|
test "when no element meets the value, or an argument is missing, the call is missing, so ?? applies" {
  inspect(
    [
      rendered(
        "${find(body.items, 'sku', 'Z-9') ?? 'no such item'}",
        input=shelves,
      ),
      rendered(
        "${find(body.items, 'sku', query.missing) ?? 'no sku'}",
        input=shelves,
      ),
      rendered(
        "${find(body.missing, 'sku', 'A-1') ?? 'no items'}",
        input=shelves,
      ),
      rendered(
        "${find(body.items, query.missing, 'A-1') ?? 'no member'}",
        input=shelves,
      ),
      rendered(
        "${find(body.items, 'sku', 'Z-9').qty ?? 'no such item'}",
        input=shelves,
      ),
      rendered_json(
        "{ \"item\": \"${find(body.items, 'sku', 'Z-9') ?? null}\" }",
        input=shelves,
      ),
      rendered("${find(body.items, 'sku', 'Z-9')}", input=shelves),
      rendered("${find(body.items, 'sku', query.missing)}", input=shelves),
    ].join("\n"),
    content=(
      #|no such item
      #|no sku
      #|no items
      #|no member
      #|no such item
      #|{"item":null}
      #|error at /response/body: find(body.items, 'sku', 'Z-9') is missing
      #|error at /response/body: query.missing is missing
    ),
  )
}

///|
test "an array that is not an array, a member that is not a string, or a value that is an object or an array is a render error" {
  let input : @template.Input = {
    ..shelves,
    body: @utf8.encode(
      (
        #|{ "items": [{ "sku": "A-1" }], "one": { "sku": "A-1" }, "text": "A-1",
        #|  "n": 1, "flag": true, "none": null, "list": ["sku"] }
      ),
    ),
  }
  inspect(
    [
      rendered("${find(body.one, 'sku', 'A-1')}", input~),
      rendered("${find(body.text, 'sku', 'A-1')}", input~),
      rendered("${find(body.none, 'sku', 'A-1')}", input~),
      rendered("${find(query.sku, 'sku', 'A-1')}", input~),
      rendered("${find(body.items, body.n, 'A-1')}", input~),
      rendered("${find(body.items, body.flag, 'A-1')}", input~),
      rendered("${find(body.items, body.none, 'A-1')}", input~),
      rendered("${find(body.items, body.list, 'A-1')}", input~),
      rendered("${find(body.items, body.one, 'A-1')}", input~),
      rendered("${find(body.items, 'sku', body.one)}", input~),
      rendered("${find(body.items, 'sku', body.list)}", input~),
      rendered(
        "${find(body.one, 'sku', 'Z-9') ?? 'a fallback does not catch it'}",
        input~,
      ),
      rendered_json(
        "{ \"item\": \"${find(body.items, 'sku', body.items)}\" }",
        input~,
      ),
    ].join("\n"),
    content=(
      #|error at /response/body: find(): argument 1 must be an array, not an object
      #|error at /response/body: find(): argument 1 must be an array, not "A-1"
      #|error at /response/body: find(): argument 1 must be an array, not null
      #|error at /response/body: find(): argument 1 must be an array, not "42"
      #|error at /response/body: find(): argument 2 must be a string, not 1
      #|error at /response/body: find(): argument 2 must be a string, not true
      #|error at /response/body: find(): argument 2 must be a string, not null
      #|error at /response/body: find(): argument 2 must be a string, not an array
      #|error at /response/body: find(): argument 2 must be a string, not an object
      #|error at /response/body: find(): argument 3 must be a string, a number, a boolean or null, not an object
      #|error at /response/body: find(): argument 3 must be a string, a number, a boolean or null, not an array
      #|error at /response/body: find(): argument 1 must be an array, not an object
      #|error at /response/json/item: find(): argument 3 must be a string, a number, a boolean or null, not an array
    ),
  )
}

///|
test "a literal argument of the wrong kind, or a call without three arguments, is a load error" {
  inspect(
    [
      rendered("${find('items', 'sku', 'A-1')}", input=shelves),
      rendered("${find(1, 'sku', 'A-1')}", input=shelves),
      rendered("${find(null, 'sku', 'A-1')}", input=shelves),
      rendered("${find(body.items ?? 'none', 'sku', 'A-1')}", input=shelves),
      rendered("${find(body.items, 1, 'A-1')}", input=shelves),
      rendered("${find(body.items, true, 'A-1')}", input=shelves),
      rendered("${find(body.items, null, 'A-1')}", input=shelves),
      rendered("${find(body.items, query.m ?? 0, 'A-1')}", input=shelves),
      rendered("${find(body.items, 'sku')}", input=shelves),
      rendered("${find(body.items, 'sku', 'A-1', 'B-7')}", input=shelves),
      rendered("${find()}", input=shelves),
      rendered_json(
        "{ \"item\": \"${find(body.items, 2, 'A-1')}\" }",
        input=shelves,
      ),
    ].join("\n"),
    content=(
      #|problem at /response/body: template: column 8: find(): argument 1 must be an array, not "items"
      #|problem at /response/body: template: column 8: find(): argument 1 must be an array, not 1
      #|problem at /response/body: template: column 8: find(): argument 1 must be an array, not null
      #|problem at /response/body: template: column 8: find(): argument 1 must be an array, not "none"
      #|problem at /response/body: template: column 20: find(): argument 2 must be a string, not 1
      #|problem at /response/body: template: column 20: find(): argument 2 must be a string, not true
      #|problem at /response/body: template: column 20: find(): argument 2 must be a string, not null
      #|problem at /response/body: template: column 20: find(): argument 2 must be a string, not 0
      #|problem at /response/body: template: column 3: find() takes 3 arguments, not 2
      #|problem at /response/body: template: column 3: find() takes 3 arguments, not 4
      #|problem at /response/body: template: column 3: find() takes 3 arguments, not 0
      #|problem at /response/json/item: template: column 20: find(): argument 2 must be a string, not 2
    ),
  )
}
