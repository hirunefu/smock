// Tests of the arithmetic helpers through the template package's public
// interface. The arithmetic is exact in decimal and uses integers only, so
// they run on native and on wasm-gc and give the same output on both.

///|
test "add, subtract and multiply are exact in decimal" {
  inspect(
    [
      rendered(
        "${add(0.1, 0.2)} ${add(1.50, 1)} ${add(-2, -3)} ${add(-1.25, 1.25)}",
      ),
      rendered("${subtract(1, 0.9)} ${subtract(0.1, 0.3)} ${subtract(-1, -1)}"),
      rendered(
        "${multiply(19.99, 3)} ${multiply(-0.5, 0.5)} ${multiply(1.1, 1.1)} ${multiply(0, -3)}",
      ),
      rendered("${multiply(123456789, 987654321)}"),
      rendered_json(
        "{ \"total\": \"${add(multiply(2, 3), subtract(0, 0.5))}\" }",
      ),
    ].join("\n"),
    content=(
      #|0.3 2.5 -5 0
      #|0.1 -0.2 0
      #|59.97 -0.25 1.21 0
      #|121932631112635269
      #|{"total":5.5}
    ),
  )
}

///|
test "divide rounds half to even at 10 decimal places, and a zero divisor is a render error" {
  inspect(
    [
      rendered(
        "${divide(10, 3)} ${divide(2, 3)} ${divide(1, 4)} ${divide(-10, 4)} ${divide(0, 5)}",
      ),
      rendered(
        "${divide(1, 2048)} ${divide(3, 2048)} ${divide(-3, 2048)} ${divide(5, 2048)}",
      ),
      rendered(
        "${divide(0.00000000005, 1)} ${divide(0.00000000015, 1)} ${divide(0.00000000025, -1)}",
      ),
      rendered(
        "${multiply(divide(1, 3), 3)} ${divide(0.1, 0.000000000000000001)}",
      ),
      rendered("${divide(5, 0)}"),
      rendered("${divide(5, '0.00')}"),
      rendered("${divide(100000000000000000, 0.1)}"),
      rendered("${divide('999999999999999999.99999999995', 1)}"),
    ].join("\n"),
    content=(
      #|3.3333333333 0.6666666667 0.25 -2.5 0
      #|0.0004882812 0.0014648438 -0.0014648438 0.0024414062
      #|0 0.0000000002 -0.0000000002
      #|0.9999999999 100000000000000000
      #|error at /response/body: divide(): argument 2, the divisor, is zero
      #|error at /response/body: divide(): argument 2, the divisor, is zero
      #|error at /response/body: divide(): the result has more than 18 digits before the point
      #|error at /response/body: divide(): the result has more than 18 digits before the point
    ),
  )
}

///|
test "modulo is the remainder of division truncated toward zero, with the sign of the dividend, as JavaScript's %" {
  inspect(
    [
      rendered(
        "${modulo(7, 3)} ${modulo(-7, 3)} ${modulo(7, -3)} ${modulo(-7, -3)}",
      ),
      rendered(
        "${modulo(5.5, 2)} ${modulo(-5.5, 2)} ${modulo(0.3, 0.1)} ${modulo(1, 0.3)}",
      ),
      rendered(
        "${modulo(6, 3)} ${modulo(-6, 3)} ${modulo(2, 5)} ${modulo(-2, 5)}",
      ),
      rendered("${modulo(5, 0)}"),
    ].join("\n"),
    content=(
      #|1 -1 1 -1
      #|1.5 -1.5 0 0.1
      #|0 0 2 -2
      #|error at /response/body: modulo(): argument 2, the divisor, is zero
    ),
  )
}

///|
test "ceil and floor go toward +∞ and −∞, round goes half away from zero, and parseInt truncates toward zero" {
  inspect(
    [
      rendered(
        "${ceil(1.2)} ${ceil(-1.2)} ${ceil(2)} ${ceil(-0.5)} ${ceil(0.000000000000000001)}",
      ),
      rendered("${floor(1.8)} ${floor(-1.2)} ${floor(-2)} ${floor(0.5)}"),
      rendered(
        "${round(2.5)} ${round(-2.5)} ${round(2.4999)} ${round(-0.4)} ${round(0.5)} ${round('1.499999999999999999')}",
      ),
      rendered(
        "${parseInt(12.7)} ${parseInt(-12.7)} ${parseInt('42')} ${parseInt(-0.5)}",
      ),
      rendered("${ceil('999999999999999999.1')}"),
      rendered("${round('-999999999999999999.5')}"),
      rendered(
        "${floor('999999999999999999.5')} ${parseInt('-999999999999999999.9')}",
      ),
    ].join("\n"),
    content=(
      #|2 -1 2 0 1
      #|1 -2 -2 0
      #|3 -3 2 0 1 1
      #|12 -12 42 0
      #|error at /response/body: ceil(): the result has more than 18 digits before the point
      #|error at /response/body: round(): the result has more than 18 digits before the point
      #|999999999999999999 -999999999999999999
    ),
  )
}

///|
test "toFixed rounds half away from zero and writes exactly the places asked for, from 0 to 18" {
  inspect(
    [
      rendered(
        "${toFixed(1.005, 2)} ${toFixed(19.99, 3)} ${toFixed(2.5, 0)} ${toFixed(-2.5, 0)}",
      ),
      rendered(
        "${toFixed(1.45, 1)} ${toFixed(-1.45, 1)} ${toFixed(0, 2)} ${toFixed(-0.001, 2)}",
      ),
      rendered(
        "${toFixed(123, 18)} ${toFixed('0.123456789012345678', 18)} ${toFixed(add(0.1, 0.2), 4)}",
      ),
      rendered_json("{ \"price\": \"${toFixed(19.99, 3)}\" }"),
      rendered("${toFixed('999999999999999999.5', 0)}"),
      rendered("${toFixed(1, 19)}"),
      rendered("${toFixed(1, -1)}"),
      rendered("${toFixed(1, 2.5)}"),
      rendered("${toFixed(1, query.lang)}"),
      rendered("${toFixed(1)}"),
    ].join("\n"),
    content=(
      #|1.01 19.990 3 -3
      #|1.5 -1.5 0.00 0.00
      #|123.000000000000000000 0.123456789012345678 0.3000
      #|{"price":19.990}
      #|error at /response/body: toFixed(): the result has more than 18 digits before the point
      #|problem at /response/body: template: column 14: toFixed(): argument 2 must be an integer literal from 0 to 18
      #|problem at /response/body: template: column 14: toFixed(): argument 2 must be an integer literal from 0 to 18
      #|problem at /response/body: template: column 14: toFixed(): argument 2 must be an integer literal from 0 to 18
      #|problem at /response/body: template: column 14: toFixed(): argument 2 must be an integer literal from 0 to 18
      #|problem at /response/body: template: column 3: toFixed() takes 2 arguments, not 1
    ),
  )
}

///|
/// A request whose query and body hold numbers, numeric text and other
/// values, for the arithmetic helpers.
let amounts : @template.Input = {
  meth: "POST",
  path: "/",
  query: [
    ("page", "4"),
    ("half", "1.5"),
    ("cents", "0.10"),
    ("exp", "1e3"),
    ("six", "six"),
    ("space", " 1"),
    ("hex", "0x10"),
    ("empty", ""),
    ("long", "1000000000000000000"),
    ("precise", "1e-19"),
  ],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "price": 19.99, "qty": 3, "tiny": 1e-7, "big": 123456789012345678,
      #|  "huge": 1e21, "flag": true, "none": null, "list": [1], "object": {} }
    ),
  ),
}

///|
test "a numeric argument is a number, taken as smock writes it, or a string that is a JSON number, taken as its own text" {
  inspect(
    [
      rendered(
        "${add('0.10', 1)} ${add(query.cents, 1)} ${add(query.page ?? 1, 1)} ${add(query.missing ?? 1, 1)}",
        input=amounts,
      ),
      rendered(
        "${multiply(body.price, body.qty)} ${add(query.half, query.page)} ${add(query.exp, 0)} ${add(body.tiny, 0)}",
        input=amounts,
      ),
      rendered("${add(query.missing, 1) ?? 'none'}", input=amounts),
      rendered("${add(query.missing, 1)}", input=amounts),
      rendered("${add(query.six, 1)}", input=amounts),
      rendered("${add(query.space, 1)}", input=amounts),
      rendered("${add(1, query.hex)}", input=amounts),
      rendered("${add(query.empty, 1)}", input=amounts),
      rendered("${round(body.flag)}", input=amounts),
      rendered("${round(body.none)}", input=amounts),
      rendered("${round(body.list)}", input=amounts),
      rendered("${round(body.object)}", input=amounts),
    ].join("\n"),
    content=(
      #|1.1 1.1 5 2
      #|59.97 5.5 1000 0.0000001
      #|none
      #|error at /response/body: query.missing is missing
      #|error at /response/body: add(): argument 1 must be a number, or a string that is one, not "six"
      #|error at /response/body: add(): argument 1 must be a number, or a string that is one, not " 1"
      #|error at /response/body: add(): argument 2 must be a number, or a string that is one, not "0x10"
      #|error at /response/body: add(): argument 1 must be a number, or a string that is one, not ""
      #|error at /response/body: round(): argument 1 must be a number, or a string that is one, not true
      #|error at /response/body: round(): argument 1 must be a number, or a string that is one, not null
      #|error at /response/body: round(): argument 1 must be a number, or a string that is one, not an array
      #|error at /response/body: round(): argument 1 must be a number, or a string that is one, not an object
    ),
  )
}

///|
test "a number literal is taken as written, with every digit a float would lose, by each arithmetic helper; elsewhere it is still written as its float" {
  inspect(
    [
      rendered(
        "${add(0.123456789012345678, 0)} ${subtract(0.123456789012345678, 0)} ${multiply(0.123456789012345678, 1)}",
      ),
      rendered(
        "${divide(123456789012345678.9, 1)} ${modulo(12345678901234567.5, 10)} ${toFixed(0.123456789012345678, 18)}",
      ),
      rendered(
        "${ceil(12345678901234566.5)} ${floor(12345678901234567.5)} ${round(12345678901234567.4)} ${parseInt(12345678901234567.9)}",
      ),
      rendered(
        "${add(query.missing ?? 0.123456789012345678, 0)} ${add(999999999999999999.9, 0)} ${add(1.50, 1e3)}",
      ),
      rendered(
        "${0.123456789012345678} ${concat(0.123456789012345678, '')} ${add(len(concat(0.123456789012345678, '')), 0)}",
      ),
      rendered_json(
        "{ \"sum\": \"${add(0.123456789012345678, 0)}\", \"literal\": \"${0.123456789012345678}\" }",
      ),
      rendered("${add(0.12345678901234567891, 0)}"),
      rendered("${add(1, query.missing ?? 1234567890123456789.5)}"),
      rendered("${toFixed(1, 2.0000000000000000001)}"),
    ].join("\n"),
    content=(
      #|0.123456789012345678 0.123456789012345678 0.123456789012345678
      #|123456789012345678.9 7.5 0.123456789012345678
      #|12345678901234567 12345678901234567 12345678901234567 12345678901234567
      #|0.123456789012345678 999999999999999999.9 1001.5
      #|0.12345678901234568 0.12345678901234568 19
      #|{"sum":0.123456789012345678,"literal":0.12345678901234568}
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not 0.12345678901234567891
      #|problem at /response/body: template: column 10: add(): argument 2 must have at most 18 digits before the point and 18 after, not 1234567890123456789.5
      #|problem at /response/body: template: column 14: toFixed(): argument 2 must be an integer literal from 0 to 18
    ),
  )
}

///|
test "a wrong argument count, or a literal that is not numeric, is a load error" {
  inspect(
    [
      rendered("${add(1)}"),
      rendered("${multiply(1, 2, 3)}"),
      rendered("${ceil(1, 2)}"),
      rendered("${parseInt()}"),
      rendered("${add('abc', 1)}"),
      rendered("${subtract(1, true)}"),
      rendered("${floor(null)}"),
      rendered("${divide(query.page ?? 'x', 1)}"),
      rendered("${modulo(1, ' 2')}"),
    ].join("\n"),
    content=(
      #|problem at /response/body: template: column 3: add() takes 2 arguments, not 1
      #|problem at /response/body: template: column 3: multiply() takes 2 arguments, not 3
      #|problem at /response/body: template: column 3: ceil() takes 1 argument, not 2
      #|problem at /response/body: template: column 3: parseInt() takes 1 argument, not 0
      #|problem at /response/body: template: column 7: add(): argument 1 must be a number, or a string that is one, not "abc"
      #|problem at /response/body: template: column 15: subtract(): argument 2 must be a number, or a string that is one, not true
      #|problem at /response/body: template: column 9: floor(): argument 1 must be a number, or a string that is one, not null
      #|problem at /response/body: template: column 10: divide(): argument 1 must be a number, or a string that is one, not "x"
      #|problem at /response/body: template: column 13: modulo(): argument 2 must be a number, or a string that is one, not " 2"
    ),
  )
}

///|
test "inputs and results have at most 18 digits before the point and 18 after, and integers keep every digit" {
  inspect(
    [
      rendered(
        "${add(body.big, 1)} ${multiply(999999999, 999999999)} ${add(9007199254740992, 1)} ${add(9007199254740993, 0)}",
        input=amounts,
      ),
      rendered(
        "${add('999999999999999999', 0)} ${add('-0.000000000000000001', 0)} ${add('1.000000000000000000000', 1)} ${add('0e999999999999', 1)}",
      ),
      rendered(
        "${add('100e-2', 0)} ${add('0.0001e4', 0)} ${add('1E+2', 0)} ${add('-0', 0)} ${add('10000000000000000000000e-22', 0)}",
      ),
      rendered("${multiply('0.000000001', '0.000000001')}"),
      rendered("${add('999999999999999999', 1)}"),
      rendered("${subtract('-999999999999999999', 1)}"),
      rendered("${multiply('1000000000', '1000000000')}"),
      rendered("${multiply('0.000000001', '0.0000000001')}"),
      rendered("${add(query.long, 0)}", input=amounts),
      rendered("${add(1, query.precise)}", input=amounts),
      rendered("${add(body.huge, 0)}", input=amounts),
      rendered("${add('1000000000000000000', 0)}"),
      rendered("${add('0.0000000000000000001', 0)}"),
      rendered("${add('1e18', 0)}"),
      rendered("${add(1000000000000000000, 0)}"),
      rendered("${add(0, 0.0000000000000000001)}"),
      rendered("${round(query.page ?? '1e-19')}"),
      rendered("${add('1e-99999999999999999999', 0)}"),
    ].join("\n"),
    content=(
      #|123456789012345679 999999998000000001 9007199254740993 9007199254740993
      #|999999999999999999 -0.000000000000000001 2 1
      #|1 1 100 0 1
      #|0.000000000000000001
      #|error at /response/body: add(): the result has more than 18 digits before the point
      #|error at /response/body: subtract(): the result has more than 18 digits before the point
      #|error at /response/body: multiply(): the result has more than 18 digits before the point
      #|error at /response/body: multiply(): the result has more than 18 digits after the point
      #|error at /response/body: add(): argument 1 must have at most 18 digits before the point and 18 after, not "1000000000000000000"
      #|error at /response/body: add(): argument 2 must have at most 18 digits before the point and 18 after, not "1e-19"
      #|error at /response/body: add(): argument 1 must have at most 18 digits before the point and 18 after, not 1e+21
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not "1000000000000000000"
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not "0.0000000000000000001"
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not "1e18"
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not 1000000000000000000
      #|problem at /response/body: template: column 10: add(): argument 2 must have at most 18 digits before the point and 18 after, not 0.0000000000000000001
      #|problem at /response/body: template: column 9: round(): argument 1 must have at most 18 digits before the point and 18 after, not "1e-19"
      #|problem at /response/body: template: column 7: add(): argument 1 must have at most 18 digits before the point and 18 after, not "1e-99999999999999999999"

    ),
  )
}

///|
test "a number with kept text, such as fake.decimal's, is taken as that text; a result is written without its trailing zeros" {
  // Each rendering starts from the same seed, so each draws 1.30.
  inspect(
    [
      rendered("${fake.decimal(1, 2, 2)}"),
      rendered("${add(fake.decimal(1, 2, 2), 0)}"),
      rendered("${toFixed(fake.decimal(1, 2, 2), 3)}"),
      rendered("${multiply(fake.decimal(1, 2, 2), 100)}"),
    ].join("\n"),
    content=(
      #|1.30
      #|1.3
      #|1.300
      #|130
    ),
  )
}

///|
test "a result is a number, which other helpers, steps and conditions take as one" {
  inspect(
    [
      rendered(
        "${padStart('7', add(2, 1), '0')} ${len(concat(multiply(0.5, 3), 'x'))} ${add(1, 2).x ?? 'not an object'}",
      ),
      rendered_json(
        "{ \"$each\": \"range(1, add(1, 2))\", \"as\": \"n\", \"do\": \"${multiply(n, 1.5)}\" }",
      ),
      rendered_json(
        "{ \"$if\": \"add(1, 2) == 3\", \"then\": \"${subtract(3, 1)}\", \"else\": \"no\" }",
      ),
      rendered_json("{ \"n\": \"${parseInt('9007199254740993.5')}\" }"),
      rendered(
        "${json(divide(1, 8))} ${raw(toFixed(1, 2))} ${divide(1, 10000000)} ${add(add(1, 2), 3)}",
      ),
    ].join("\n"),
    content=(
      #|007 4 not an object
      #|[1.5,3,4.5]
      #|2
      #|{"n":9007199254740993}
      #|0.125 1.00 0.0000001 6
    ),
  )
}

///|
test "a result whose kept text has a fraction is not an integer, though its float has none; one whose fraction is only zeros is" {
  inspect(
    [
      rendered("${substr('abcdef', add(1, '0.000000000000000001'))}"),
      rendered("${json(range(1, add(3, '0.000000000000000001')))}"),
      rendered_json(
        "{ \"$each\": \"range(1, add(3, '0.000000000000000001'))\", \"as\": \"n\", \"do\": \"${n}\" }",
      ),
      rendered("${substr('abcdef', toFixed(1, 2))}"),
      rendered("${json(range(1, toFixed(3, 1)))}"),
      rendered("${substr('abcdef', '1.0000000000000000001')}"),
    ].join("\n"),
    content=(
      #|error at /response/body: substr(): argument 2 must be an integer, or a string that is one, not 1.000000000000000001
      #|error at /response/body: range() takes integers from -9007199254740991 to 9007199254740991, not 3.000000000000000001
      #|error at /response/json/$each: range() takes integers from -9007199254740991 to 9007199254740991, not 3.000000000000000001
      #|bcdef
      #|[1,2,3]
      #|bcdef
    ),
  )
}
