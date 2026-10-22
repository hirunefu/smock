///|
/// Parses `text` in the mode for OpenAPI documents and renders the tree as
/// compact JSON, or the error as `error <pointer>: <message>`.
fn openapi(text : String) -> String {
  try @yaml.parse(text, openapi=true) catch {
    @yaml.ParseError(pointer~, message~) => "error \{pointer}: \{message}"
  } noraise {
    tree => tree.stringify()
  }
}

///|
/// Parses each of `values` as the value of key `a` in the mode for OpenAPI
/// documents, and renders the results, one per line.
fn openapi_values(values : Array[String]) -> String {
  values.map(value => "\{value} -> \{openapi("a: \{value}")}").join("\n")
}

///|
/// An OpenAPI document that the safe subset rejects.
let openapi_document : String =
  #|openapi: 3.1.0
  #|paths:
  #|  /pets:
  #|    get:
  #|      responses:
  #|        200:
  #|          description: A pet
  #|          content:
  #|            application/json:
  #|              example: { born: 2020-01-01, code: 007, tag: ~, legacy: yes }

///|
test "an OpenAPI document with an unquoted status key and a date reads in the OpenAPI mode" {
  inspect(
    openapi(openapi_document),
    content=(
      #|{"openapi":"3.1.0","paths":{"/pets":{"get":{"responses":{"200":{"description":"A pet","content":{"application/json":{"example":{"born":"2020-01-01","code":7,"tag":null,"legacy":"yes"}}}}}}}}}
    ),
  )
}

///|
/// Plain scalars that the YAML 1.2 core schema types as null, booleans or
/// numbers.
let core_typed : Array[String] = [
  "null", "Null", "NULL", "~", "true", "True", "TRUE", "false", "False", "FALSE",
  "0x1F", "0o17", "+1", ".5", "007",
]

///|
test "in the OpenAPI mode, plain scalars are typed by the YAML 1.2 core schema" {
  inspect(
    openapi_values(core_typed),
    content=(
      #|null -> {"a":null}
      #|Null -> {"a":null}
      #|NULL -> {"a":null}
      #|~ -> {"a":null}
      #|true -> {"a":true}
      #|True -> {"a":true}
      #|TRUE -> {"a":true}
      #|false -> {"a":false}
      #|False -> {"a":false}
      #|FALSE -> {"a":false}
      #|0x1F -> {"a":31}
      #|0o17 -> {"a":15}
      #|+1 -> {"a":1}
      #|.5 -> {"a":0.5}
      #|007 -> {"a":7}
    ),
  )
}

///|
/// Plain scalars that the YAML 1.2 core schema reads as strings, though
/// YAML 1.1 types some of them, and some look like numbers.
let core_strings : Array[String] = [
  "yes", "no", "on", "off", "y", "N", "Yes", "OFF", "nULL", "tRUE", "2020-01-01",
  "2001-12-14T21:59:43Z", "1_000", "1_000.5", "0b1010", "1:30", "190:20:30", "-0x1F",
  "+0x1F", "0X1F", "0x", "0xG", "0o", "0o8", "0O17", "1.2.3", "1.5e3_0", "1e", ".",
  "+", ".e3", "<<", "=", "-.nan", ".infinity",
]

///|
test "in the OpenAPI mode, other spellings of YAML 1.1 types are strings" {
  inspect(
    openapi_values(core_strings),
    content=(
      #|yes -> {"a":"yes"}
      #|no -> {"a":"no"}
      #|on -> {"a":"on"}
      #|off -> {"a":"off"}
      #|y -> {"a":"y"}
      #|N -> {"a":"N"}
      #|Yes -> {"a":"Yes"}
      #|OFF -> {"a":"OFF"}
      #|nULL -> {"a":"nULL"}
      #|tRUE -> {"a":"tRUE"}
      #|2020-01-01 -> {"a":"2020-01-01"}
      #|2001-12-14T21:59:43Z -> {"a":"2001-12-14T21:59:43Z"}
      #|1_000 -> {"a":"1_000"}
      #|1_000.5 -> {"a":"1_000.5"}
      #|0b1010 -> {"a":"0b1010"}
      #|1:30 -> {"a":"1:30"}
      #|190:20:30 -> {"a":"190:20:30"}
      #|-0x1F -> {"a":"-0x1F"}
      #|+0x1F -> {"a":"+0x1F"}
      #|0X1F -> {"a":"0X1F"}
      #|0x -> {"a":"0x"}
      #|0xG -> {"a":"0xG"}
      #|0o -> {"a":"0o"}
      #|0o8 -> {"a":"0o8"}
      #|0O17 -> {"a":"0O17"}
      #|1.2.3 -> {"a":"1.2.3"}
      #|1.5e3_0 -> {"a":"1.5e3_0"}
      #|1e -> {"a":"1e"}
      #|. -> {"a":"."}
      #|+ -> {"a":"+"}
      #|.e3 -> {"a":".e3"}
      #|<< -> {"a":"<<"}
      #|= -> {"a":"="}
      #|-.nan -> {"a":"-.nan"}
      #|.infinity -> {"a":".infinity"}
    ),
  )
}

///|
/// Decimal numbers of the YAML 1.2 core schema, with the same number in
/// JSON syntax.
let core_decimals : Array[(String, String)] = [
  ("-012", "-12"),
  ("08", "8"),
  ("+0", "0"),
  ("-0", "-0"),
  ("000", "0"),
  ("09.5", "9.5"),
  ("00.5", "0.5"),
  ("1.", "1"),
  ("-1.", "-1"),
  ("1.e3", "1e3"),
  ("+1.5", "1.5"),
  ("-.5", "-0.5"),
  ("+.5e-3", "0.5e-3"),
  ("1.50", "1.50"),
  ("1E+2", "1E+2"),
  ("2.5e-003", "2.5e-003"),
  ("12345678901234567890", "12345678901234567890"),
  ("+12345678901234567890", "12345678901234567890"),
  ("-0012345678901234567890", "-12345678901234567890"),
  ("1e400", "1e400"),
]

///|
test "in the OpenAPI mode, decimal numbers read as the same number in JSON syntax would" {
  for number in core_decimals {
    let (yaml, json) = number
    assert_eq(
      @yaml.parse("a: \{yaml}", openapi=true),
      @json.parse("{\"a\": \{json}}"),
      msg="\{yaml} should read as \{json}",
    )
  }
  // A decimal integer keeps its digits, as in JSON.
  debug_inspect(
    @yaml.parse(
      "[+12345678901234567890, -0012345678901234567890]",
      openapi=true,
    ),
    content=(
      #|Array(
      #|  [
      #|    Number(12345678901234567000, repr=Some("12345678901234567890")),
      #|    Number(-12345678901234567000, repr=Some("-12345678901234567890")),
      #|  ],
      #|)
    ),
  )
}

///|
/// Renders `openapi` for each case, one per line.
fn openapi_each(cases : Array[String]) -> String {
  cases.map(text => "\{text.escape()} -> \{openapi(text)}").join("\n")
}

///|
/// Mappings whose plain keys YAML may type, but OpenAPI reads as strings.
let string_keys : Array[String] = [
  "200: x", "true: x", "null: x", "~: x", "on: x", "0x1F: x", "1.5: x", "2020-01-01: x",
  "{404: x, default: y}", "{yes: 1}", "'200': x", "200: a\n'200': b", "{1: a, '1': b}",
]

///|
test "in the OpenAPI mode, every key is a string" {
  inspect(
    openapi_each(string_keys),
    content=(
      #|"200: x" -> {"200":"x"}
      #|"true: x" -> {"true":"x"}
      #|"null: x" -> {"null":"x"}
      #|"~: x" -> {"~":"x"}
      #|"on: x" -> {"on":"x"}
      #|"0x1F: x" -> {"0x1F":"x"}
      #|"1.5: x" -> {"1.5":"x"}
      #|"2020-01-01: x" -> {"2020-01-01":"x"}
      #|"{404: x, default: y}" -> {"404":"x","default":"y"}
      #|"{yes: 1}" -> {"yes":1}
      #|"'200': x" -> {"200":"x"}
      #|"200: a\n'200': b" -> error /200: duplicate key
      #|"{1: a, '1': b}" -> error /1: duplicate key
    ),
  )
}

///|
/// Numbers of the YAML 1.2 core schema at the edge of what JSON holds.
let core_limits : Array[String] = [
  "0x1FFFFFFFFFFFFF", "0x001FFFFFFFFFFFFF", "0x20000000000000", "0xFFFFFFFFFFFFFFFFFFFF",
  "0o377777777777777777", "0o400000000000000000", ".inf", "-.inf", "+.Inf", ".INF",
  ".nan", ".NaN", ".NAN",
]

///|
test "in the OpenAPI mode, hexadecimal and octal integers above 2^53 - 1, .inf and .nan are errors" {
  inspect(
    openapi_values(core_limits),
    content=(
      #|0x1FFFFFFFFFFFFF -> {"a":9007199254740991}
      #|0x001FFFFFFFFFFFFF -> {"a":9007199254740991}
      #|0x20000000000000 -> error /a: "0x20000000000000" is above 2^53 - 1; write it in decimal, or quote this value
      #|0xFFFFFFFFFFFFFFFFFFFF -> error /a: "0xFFFFFFFFFFFFFFFFFFFF" is above 2^53 - 1; write it in decimal, or quote this value
      #|0o377777777777777777 -> {"a":9007199254740991}
      #|0o400000000000000000 -> error /a: "0o400000000000000000" is above 2^53 - 1; write it in decimal, or quote this value
      #|.inf -> error /a: ".inf" is infinity, which JSON cannot hold; quote this value
      #|-.inf -> error /a: "-.inf" is infinity, which JSON cannot hold; quote this value
      #|+.Inf -> error /a: "+.Inf" is infinity, which JSON cannot hold; quote this value
      #|.INF -> error /a: ".INF" is infinity, which JSON cannot hold; quote this value
      #|.nan -> error /a: ".nan" is NaN, which JSON cannot hold; quote this value
      #|.NaN -> error /a: ".NaN" is NaN, which JSON cannot hold; quote this value
      #|.NAN -> error /a: ".NAN" is NaN, which JSON cannot hold; quote this value
    ),
  )
  // The same in a flow collection, and quoted, they are strings.
  inspect(
    openapi("[.inf, '.nan', \"0x20000000000000\"]"),
    content=(
      #|error /0: ".inf" is infinity, which JSON cannot hold; quote this value
    ),
  )
  inspect(
    openapi("['.inf', '.nan', \"0x20000000000000\"]"),
    content=(
      #|[".inf",".nan","0x20000000000000"]
    ),
  )
}

///|
/// Collections with empty values.
let empty_values : Array[String] = [
  "a:", "a:\nb: 1", "a: # comment\nb: 1", "a:\n  # comment\nb: 1", "- ", "-\n- b",
  "-\n-\n", "a:\n  -\n  - x\n", "a:\n  b:\n  c: 1\n", "{a: }", "{a: , b: 1}", "{a}",
  "{a, b: 1}", "a: {x}\n",
]

///|
test "in the OpenAPI mode, an empty value is null" {
  inspect(
    openapi_each(empty_values),
    content=(
      #|"a:" -> {"a":null}
      #|"a:\nb: 1" -> {"a":null,"b":1}
      #|"a: # comment\nb: 1" -> {"a":null,"b":1}
      #|"a:\n  # comment\nb: 1" -> {"a":null,"b":1}
      #|"- " -> [null]
      #|"-\n- b" -> [null,"b"]
      #|"-\n-\n" -> [null,null]
      #|"a:\n  -\n  - x\n" -> {"a":[null,"x"]}
      #|"a:\n  b:\n  c: 1\n" -> {"a":{"b":null,"c":1}}
      #|"{a: }" -> {"a":null}
      #|"{a: , b: 1}" -> {"a":null,"b":1}
      #|"{a}" -> {"a":null}
      #|"{a, b: 1}" -> {"a":null,"b":1}
      #|"a: {x}\n" -> {"a":{"x":null}}
    ),
  )
}

///|
/// Block scalars with indentation indicators.
let indentation_indicators : Array[String] = [
  "a: |2\n    code\n  text\n\n", "a: |2-\n    code\n  text\n\n", "a: |-2\n    code\n  text\n\n",
  "a: |2+\n    code\n  text\n\n", "a: |+2\n    code\n  text\n\n", "a: >2\n    code\n  text\n  more\n",
  "a: >-1\n  x\n y\n", "a: >1+\n  x\n y\n\n", "a: |1 # comment\n  x\n", "- |1\n  explicit\n",
  "a:\n  b: |2\n      x\n    y\n  c: 1\n", "a: |1\n   \n  x\n", "a: |2\n  x\n\n   \n  y\n",
  "a: |9\n          x\n", "a: |2\n  x\nb: 1\n",
]

///|
test "in the OpenAPI mode, indentation indicators set a block scalar's indentation, with each chomping indicator" {
  inspect(
    openapi_each(indentation_indicators),
    content=(
      #|"a: |2\n    code\n  text\n\n" -> {"a":"  code\ntext\n"}
      #|"a: |2-\n    code\n  text\n\n" -> {"a":"  code\ntext"}
      #|"a: |-2\n    code\n  text\n\n" -> {"a":"  code\ntext"}
      #|"a: |2+\n    code\n  text\n\n" -> {"a":"  code\ntext\n\n"}
      #|"a: |+2\n    code\n  text\n\n" -> {"a":"  code\ntext\n\n"}
      #|"a: >2\n    code\n  text\n  more\n" -> {"a":"  code\ntext more\n"}
      #|"a: >-1\n  x\n y\n" -> {"a":" x\ny"}
      #|"a: >1+\n  x\n y\n\n" -> {"a":" x\ny\n\n"}
      #|"a: |1 # comment\n  x\n" -> {"a":" x\n"}
      #|"- |1\n  explicit\n" -> [" explicit\n"]
      #|"a:\n  b: |2\n      x\n    y\n  c: 1\n" -> {"a":{"b":"  x\ny\n","c":1}}
      #|"a: |1\n   \n  x\n" -> {"a":"  \n x\n"}
      #|"a: |2\n  x\n\n   \n  y\n" -> {"a":"x\n\n \ny\n"}
      #|"a: |9\n          x\n" -> {"a":" x\n"}
      #|"a: |2\n  x\nb: 1\n" -> {"a":"x\n","b":1}
    ),
  )
  // A line indented less than the indicator says ends the scalar.
  inspect(
    openapi_each(["a: |2\n x\n", "a: |2\n  x\n y\n"]),
    content=(
      #|"a: |2\n x\n" -> error /a: bad indentation
      #|"a: |2\n  x\n y\n" -> error /a: bad indentation
    ),
  )
}

///|
/// Renders each case as the safe subset and the OpenAPI mode read it.
fn both(cases : Array[String]) -> String {
  cases
  .map(text => {
    "\{text.escape()}\n  safe: \{yaml(text)}\n  openapi: \{openapi(text)}"
  })
  .join("\n")
}

///|
test "anchors, aliases, tags, merge keys, duplicate keys, several documents, directives and explicit keys are errors in both modes" {
  inspect(
    both([
      "a: &x 1", "a: *x", "base: &base {a: 1}\nother: *base", "hosts: [*.example.com]",
      "a: !!str 1", "&x a: 1", "merged:\n  <<: {b: 2}", "{<<: {a: 1}}", "a: 1\nb: 2\na: 3",
      "- {a: 1, a: 2}", "a: 1\n---\nb: 2", "a: 1\n...\nb: 2", "%YAML 1.2\n---\na: 1",
      "? a\n: b", "{? a: b}",
    ]),
    content=(
      #|"a: &x 1"
      #|  safe: error /a: anchors (&) are not supported; quote the value if it is text
      #|  openapi: error /a: anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
      #|"a: *x"
      #|  safe: error /a: aliases (*) are not supported; quote the value if it is text
      #|  openapi: error /a: aliases (*) are not supported; reuse parts with $ref, or quote the value if it is text
      #|"base: &base {a: 1}\nother: *base"
      #|  safe: error /base: anchors (&) are not supported; quote the value if it is text
      #|  openapi: error /base: anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
      #|"hosts: [*.example.com]"
      #|  safe: error /hosts/0: aliases (*) are not supported; quote the value if it is text
      #|  openapi: error /hosts/0: aliases (*) are not supported; reuse parts with $ref, or quote the value if it is text
      #|"a: !!str 1"
      #|  safe: error /a: tags (!) are not supported; quote the value if it is text
      #|  openapi: error /a: tags (!) are not supported; quote the value if it is text
      #|"&x a: 1"
      #|  safe: error : anchors (&) are not supported; quote the value if it is text
      #|  openapi: error : anchors (&) are not supported; reuse parts with $ref, or quote the value if it is text
      #|"merged:\n  <<: {b: 2}"
      #|  safe: error /merged/<<: merge keys (<<) are not supported
      #|  openapi: error /merged/<<: merge keys (<<) are not supported
      #|"{<<: {a: 1}}"
      #|  safe: error /<<: merge keys (<<) are not supported
      #|  openapi: error /<<: merge keys (<<) are not supported
      #|"a: 1\nb: 2\na: 3"
      #|  safe: error /a: duplicate key
      #|  openapi: error /a: duplicate key
      #|"- {a: 1, a: 2}"
      #|  safe: error /0/a: duplicate key
      #|  openapi: error /0/a: duplicate key
      #|"a: 1\n---\nb: 2"
      #|  safe: error : multiple documents are not supported
      #|  openapi: error : multiple documents are not supported
      #|"a: 1\n...\nb: 2"
      #|  safe: error : multiple documents are not supported
      #|  openapi: error : multiple documents are not supported
      #|"%YAML 1.2\n---\na: 1"
      #|  safe: error : directives (%) are not supported
      #|  openapi: error : directives (%) are not supported
      #|"? a\n: b"
      #|  safe: error : explicit keys (?) are not supported
      #|  openapi: error : explicit keys (?) are not supported
      #|"{? a: b}"
      #|  safe: error : explicit keys (?) are not supported
      #|  openapi: error : explicit keys (?) are not supported
    ),
  )
}

///|
test "malformed text gives the same error in both modes" {
  inspect(
    both([
      "", "a:\n\tb: 1", "a: \u{7}", "a: \"abc", "a: [1, 2", "[a, , b]", ": x", "a: |0\n  x",
      "a: |22\n  x", "a: |2-+\n  x", "a: |-2-\n  x", "a: |x",
    ]),
    content=(
      #|""
      #|  safe: error : the document is empty
      #|  openapi: error : the document is empty
      #|"a:\n\tb: 1"
      #|  safe: error /a: tabs are not allowed in indentation
      #|  openapi: error /a: tabs are not allowed in indentation
      #|"a: \u{07}"
      #|  safe: error : U+0007 is a control character; write it as an escape in a double-quoted value
      #|  openapi: error : U+0007 is a control character; write it as an escape in a double-quoted value
      #|"a: \"abc"
      #|  safe: error /a: unterminated double-quoted value
      #|  openapi: error /a: unterminated double-quoted value
      #|"a: [1, 2"
      #|  safe: error /a/1: unterminated flow sequence
      #|  openapi: error /a/1: unterminated flow sequence
      #|"[a, , b]"
      #|  safe: error /1: expected a value before ','
      #|  openapi: error /1: expected a value before ','
      #|": x"
      #|  safe: error : a key must not be empty
      #|  openapi: error : a key must not be empty
      #|"a: |0\n  x"
      #|  safe: error /a: block scalar indentation indicators are not supported
      #|  openapi: error /a: invalid block scalar header
      #|"a: |22\n  x"
      #|  safe: error /a: block scalar indentation indicators are not supported
      #|  openapi: error /a: invalid block scalar header
      #|"a: |2-+\n  x"
      #|  safe: error /a: block scalar indentation indicators are not supported
      #|  openapi: error /a: invalid block scalar header
      #|"a: |-2-\n  x"
      #|  safe: error /a: block scalar indentation indicators are not supported
      #|  openapi: error /a: invalid block scalar header
      #|"a: |x"
      #|  safe: error /a: invalid block scalar header
      #|  openapi: error /a: invalid block scalar header
    ),
  )
}

///|
test "every input the OpenAPI mode accepts here, the safe subset rejects, or reads as the same tree" {
  let inputs = [openapi_document]
  for value in core_typed + core_strings + core_limits {
    inputs.push("a: \{value}")
  }
  for number in core_decimals {
    inputs.push("a: \{number.0}")
  }
  inputs.append(string_keys + empty_values + indentation_indicators)
  let safe = []
  for text in inputs {
    let tree = @yaml.parse(text, openapi=true) catch { _ => continue }
    // What the safe subset reads, it reads as the same tree.
    let result = yaml(text)
    if !result.has_prefix("error ") {
      assert_eq(result, tree.stringify(), msg=text)
    }
    safe.push("\{text.escape()} -> \{result}")
  }
  inspect(
    safe.join("\n"),
    content=(
      #|"openapi: 3.1.0\npaths:\n  /pets:\n    get:\n      responses:\n        200:\n          description: A pet\n          content:\n            application/json:\n              example: { born: 2020-01-01, code: 007, tag: ~, legacy: yes }" -> error /openapi: "3.1.0" may be read as a number; quote this value
      #|"a: null" -> {"a":null}
      #|"a: Null" -> error /a: "Null" may be read as null; quote this value
      #|"a: NULL" -> error /a: "NULL" may be read as null; quote this value
      #|"a: ~" -> error /a: "~" may be read as null; quote this value
      #|"a: true" -> {"a":true}
      #|"a: True" -> error /a: "True" may be read as a boolean; quote this value
      #|"a: TRUE" -> error /a: "TRUE" may be read as a boolean; quote this value
      #|"a: false" -> {"a":false}
      #|"a: False" -> error /a: "False" may be read as a boolean; quote this value
      #|"a: FALSE" -> error /a: "FALSE" may be read as a boolean; quote this value
      #|"a: 0x1F" -> error /a: "0x1F" may be read as a number; quote this value
      #|"a: 0o17" -> error /a: "0o17" may be read as a number; quote this value
      #|"a: +1" -> error /a: "+1" may be read as a number; quote this value
      #|"a: .5" -> error /a: ".5" may be read as a number; quote this value
      #|"a: 007" -> error /a: "007" may be read as a number; quote this value
      #|"a: yes" -> error /a: "yes" may be read as a boolean; quote this value
      #|"a: no" -> error /a: "no" may be read as a boolean; quote this value
      #|"a: on" -> error /a: "on" may be read as a boolean; quote this value
      #|"a: off" -> error /a: "off" may be read as a boolean; quote this value
      #|"a: y" -> error /a: "y" may be read as a boolean; quote this value
      #|"a: N" -> error /a: "N" may be read as a boolean; quote this value
      #|"a: Yes" -> error /a: "Yes" may be read as a boolean; quote this value
      #|"a: OFF" -> error /a: "OFF" may be read as a boolean; quote this value
      #|"a: nULL" -> error /a: "nULL" may be read as null; quote this value
      #|"a: tRUE" -> error /a: "tRUE" may be read as a boolean; quote this value
      #|"a: 2020-01-01" -> error /a: "2020-01-01" may be read as a timestamp; quote this value
      #|"a: 2001-12-14T21:59:43Z" -> error /a: "2001-12-14T21:59:43Z" may be read as a timestamp; quote this value
      #|"a: 1_000" -> error /a: "1_000" may be read as a number; quote this value
      #|"a: 1_000.5" -> error /a: "1_000.5" may be read as a number; quote this value
      #|"a: 0b1010" -> error /a: "0b1010" may be read as a number; quote this value
      #|"a: 1:30" -> error /a: "1:30" may be read as a number; quote this value
      #|"a: 190:20:30" -> error /a: "190:20:30" may be read as a number; quote this value
      #|"a: -0x1F" -> error /a: "-0x1F" may be read as a number; quote this value
      #|"a: +0x1F" -> error /a: "+0x1F" may be read as a number; quote this value
      #|"a: 0X1F" -> {"a":"0X1F"}
      #|"a: 0x" -> {"a":"0x"}
      #|"a: 0xG" -> {"a":"0xG"}
      #|"a: 0o" -> {"a":"0o"}
      #|"a: 0o8" -> {"a":"0o8"}
      #|"a: 0O17" -> {"a":"0O17"}
      #|"a: 1.2.3" -> error /a: "1.2.3" may be read as a number; quote this value
      #|"a: 1.5e3_0" -> {"a":"1.5e3_0"}
      #|"a: 1e" -> {"a":"1e"}
      #|"a: ." -> {"a":"."}
      #|"a: +" -> {"a":"+"}
      #|"a: .e3" -> {"a":".e3"}
      #|"a: <<" -> error /a: "<<" may be read as a merge key; quote this value
      #|"a: =" -> error /a: "=" may be read as a value key; quote this value
      #|"a: -.nan" -> {"a":"-.nan"}
      #|"a: .infinity" -> {"a":".infinity"}
      #|"a: 0x1FFFFFFFFFFFFF" -> error /a: "0x1FFFFFFFFFFFFF" may be read as a number; quote this value
      #|"a: 0x001FFFFFFFFFFFFF" -> error /a: "0x001FFFFFFFFFFFFF" may be read as a number; quote this value
      #|"a: 0o377777777777777777" -> error /a: "0o377777777777777777" may be read as a number; quote this value
      #|"a: -012" -> error /a: "-012" may be read as a number; quote this value
      #|"a: 08" -> error /a: "08" may be read as a number; quote this value
      #|"a: +0" -> error /a: "+0" may be read as a number; quote this value
      #|"a: -0" -> {"a":0}
      #|"a: 000" -> error /a: "000" may be read as a number; quote this value
      #|"a: 09.5" -> error /a: "09.5" may be read as a number; quote this value
      #|"a: 00.5" -> error /a: "00.5" may be read as a number; quote this value
      #|"a: 1." -> error /a: "1." may be read as a number; quote this value
      #|"a: -1." -> error /a: "-1." may be read as a number; quote this value
      #|"a: 1.e3" -> error /a: "1.e3" may be read as a number; quote this value
      #|"a: +1.5" -> error /a: "+1.5" may be read as a number; quote this value
      #|"a: -.5" -> error /a: "-.5" may be read as a number; quote this value
      #|"a: +.5e-3" -> error /a: "+.5e-3" may be read as a number; quote this value
      #|"a: 1.50" -> {"a":1.5}
      #|"a: 1E+2" -> {"a":100}
      #|"a: 2.5e-003" -> {"a":0.0025}
      #|"a: 12345678901234567890" -> {"a":12345678901234567890}
      #|"a: +12345678901234567890" -> error /a: "+12345678901234567890" may be read as a number; quote this value
      #|"a: -0012345678901234567890" -> error /a: "-0012345678901234567890" may be read as a number; quote this value
      #|"a: 1e400" -> {"a":1e400}
      #|"200: x" -> error /200: "200" is read as a number; quote this key
      #|"true: x" -> error /true: "true" is read as a boolean; quote this key
      #|"null: x" -> error /null: "null" is read as null; quote this key
      #|"~: x" -> error /~0: "~" may be read as null; quote this key
      #|"on: x" -> error /on: "on" may be read as a boolean; quote this key
      #|"0x1F: x" -> error /0x1F: "0x1F" may be read as a number; quote this key
      #|"1.5: x" -> error /1.5: "1.5" is read as a number; quote this key
      #|"2020-01-01: x" -> error /2020-01-01: "2020-01-01" may be read as a timestamp; quote this key
      #|"{404: x, default: y}" -> error /404: "404" is read as a number; quote this key
      #|"{yes: 1}" -> error /yes: "yes" may be read as a boolean; quote this key
      #|"'200': x" -> {"200":"x"}
      #|"a:" -> error /a: empty value: write null, or "" for an empty string
      #|"a:\nb: 1" -> error /a: empty value: write null, or "" for an empty string
      #|"a: # comment\nb: 1" -> error /a: empty value: write null, or "" for an empty string
      #|"a:\n  # comment\nb: 1" -> error /a: empty value: write null, or "" for an empty string
      #|"- " -> error /0: empty value: write null, or "" for an empty string
      #|"-\n- b" -> error /0: empty value: write null, or "" for an empty string
      #|"-\n-\n" -> error /0: empty value: write null, or "" for an empty string
      #|"a:\n  -\n  - x\n" -> error /a/0: empty value: write null, or "" for an empty string
      #|"a:\n  b:\n  c: 1\n" -> error /a/b: empty value: write null, or "" for an empty string
      #|"{a: }" -> error /a: empty value: write null, or "" for an empty string
      #|"{a: , b: 1}" -> error /a: empty value: write null, or "" for an empty string
      #|"{a}" -> error /a: empty value: write null, or "" for an empty string
      #|"{a, b: 1}" -> error /a: empty value: write null, or "" for an empty string
      #|"a: {x}\n" -> error /a/x: empty value: write null, or "" for an empty string
      #|"a: |2\n    code\n  text\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |2-\n    code\n  text\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |-2\n    code\n  text\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |2+\n    code\n  text\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |+2\n    code\n  text\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: >2\n    code\n  text\n  more\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: >-1\n  x\n y\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: >1+\n  x\n y\n\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |1 # comment\n  x\n" -> error /a: block scalar indentation indicators are not supported
      #|"- |1\n  explicit\n" -> error /0: block scalar indentation indicators are not supported
      #|"a:\n  b: |2\n      x\n    y\n  c: 1\n" -> error /a/b: block scalar indentation indicators are not supported
      #|"a: |1\n   \n  x\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |2\n  x\n\n   \n  y\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |9\n          x\n" -> error /a: block scalar indentation indicators are not supported
      #|"a: |2\n  x\nb: 1\n" -> error /a: block scalar indentation indicators are not supported
    ),
  )
}
