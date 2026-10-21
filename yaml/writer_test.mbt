///|
/// Writes `value` as YAML and returns the text, or the error as
/// `error <pointer>: <message>`.
fn written(
  value : Json,
  comment? : Array[String] = [],
  item_comments? : Map[String, Array[String]] = {},
) -> String {
  try @yaml.write(value, comment~, item_comments~) catch {
    @yaml.WriteError(pointer~, message~) => "error \{pointer}: \{message}"
  } noraise {
    bytes => @utf8.decode(bytes) catch { _ => "error: not UTF-8" }
  }
}

///|
test "a tree is written in block style, two spaces per level, quoting only what needs it" {
  let stub = @json.parse(
    (
      #|{ "request": { "method": "GET", "path": { "pattern": "/v1/pets/[^/]+" },
      #|               "headers": { "Smock-Status": "404" } },
      #|  "response": { "status": 404,
      #|                "json": { "on": "yes", "born": "2000-01-01", "tags": [] } } }
    ),
  )
  inspect(
    written(stub),
    content=(
      #|request:
      #|  method: GET
      #|  path:
      #|    pattern: /v1/pets/[^/]+
      #|  headers:
      #|    Smock-Status: "404"
      #|response:
      #|  status: 404
      #|  json:
      #|    "on": "yes"
      #|    born: "2000-01-01"
      #|    tags: []
      #|
    ),
  )
}

///|
test "a sequence's items start with -; a mapping or sequence item starts on the same line" {
  let tree = @json.parse(
    (
      #|{ "mocks": [{ "name": "petstore", "hosts": ["a.example", "b.example"] }],
      #|  "matrix": [[1, 2], [[3], []], [{}], [{ "a": [true, null] }]],
      #|  "empty": {} }
    ),
  )
  inspect(
    written(tree),
    content=(
      #|mocks:
      #|  - name: petstore
      #|    hosts:
      #|      - a.example
      #|      - b.example
      #|matrix:
      #|  - - 1
      #|    - 2
      #|  - - - 3
      #|    - []
      #|  - - {}
      #|  - - a:
      #|        - true
      #|        - null
      #|empty: {}
      #|
    ),
  )
  inspect(
    written(@json.parse("[{\"a\": 1, \"b\": {\"c\": 2}}, \"x\"]")),
    content=(
      #|- a: 1
      #|  b:
      #|    c: 2
      #|- x
      #|
    ),
  )
}

///|
test "a scalar or an empty collection is a document of one line" {
  inspect(written(Json::string("x")), content="x\n")
  inspect(written(Json::string("yes")), content="\"yes\"\n")
  inspect(written(Json::number(1.5)), content="1.5\n")
  inspect(written(Json::null()), content="null\n")
  inspect(written(Json::boolean(false)), content="false\n")
  inspect(written(Json::object({})), content="{}\n")
  inspect(written(Json::array([])), content="[]\n")
}

///|
/// Strings that need quotes in some place, and some that look as if they
/// did but do not.
let quoting_cases : Array[String] = [
  "GET", "/v1/pets/[^/]+", "404", "1.5", "1e3", "0x1F", "1_000", ".inf", "yes", "on",
  "No", "null", "Null", "true", "~", "<<", "=", "", "2000-01-01", " lead", "trail ",
  "a: b", "a:b", "a:", "http://example.com", "a #b", "a#b", "- x", "-", "-x", "-1",
  "? x", "?", "?x", ": x", ":", ":x", "&a", "*a", "!a", "#a", "|", ">", "%a", "@a",
  "`a", "[a]", "{a}", ",a", "\"a", "'a", "a\"b", "a'b", "---", "--- x", "---x", "...",
  "... x", "café", "日本語", "😀",
]

///|
test "strings and keys are double-quoted unless the parser reads them back plain, in that place" {
  // As values: items of a sequence.
  inspect(
    written(Json::array(quoting_cases.map(Json::string))),
    content=(
      #|- GET
      #|- /v1/pets/[^/]+
      #|- "404"
      #|- "1.5"
      #|- "1e3"
      #|- "0x1F"
      #|- "1_000"
      #|- ".inf"
      #|- "yes"
      #|- "on"
      #|- "No"
      #|- "null"
      #|- "Null"
      #|- "true"
      #|- "~"
      #|- "<<"
      #|- "="
      #|- ""
      #|- "2000-01-01"
      #|- " lead"
      #|- "trail "
      #|- "a: b"
      #|- a:b
      #|- "a:"
      #|- http://example.com
      #|- "a #b"
      #|- a#b
      #|- "- x"
      #|- "-"
      #|- -x
      #|- "-1"
      #|- "? x"
      #|- "?"
      #|- ?x
      #|- ": x"
      #|- ":"
      #|- :x
      #|- "&a"
      #|- "*a"
      #|- "!a"
      #|- "#a"
      #|- "|"
      #|- ">"
      #|- "%a"
      #|- "@a"
      #|- "`a"
      #|- "[a]"
      #|- "{a}"
      #|- ",a"
      #|- "\"a"
      #|- "'a"
      #|- a"b
      #|- a'b
      #|- ---
      #|- --- x
      #|- ---x
      #|- ...
      #|- ... x
      #|- café
      #|- 日本語
      #|- 😀
      #|
    ),
  )
  // As keys of the top mapping, at the start of a line. A key is followed
  // by `:`, so `a:`, `-`, `?`, `:` and `---` need no quotes there.
  let keys = Map::from_array(quoting_cases.map(s => (s, Json::number(1))))
  inspect(
    written(Json::object(keys)),
    content=(
      #|GET: 1
      #|/v1/pets/[^/]+: 1
      #|"404": 1
      #|"1.5": 1
      #|"1e3": 1
      #|"0x1F": 1
      #|"1_000": 1
      #|".inf": 1
      #|"yes": 1
      #|"on": 1
      #|"No": 1
      #|"null": 1
      #|"Null": 1
      #|"true": 1
      #|"~": 1
      #|"<<": 1
      #|"=": 1
      #|"": 1
      #|"2000-01-01": 1
      #|" lead": 1
      #|"trail ": 1
      #|"a: b": 1
      #|a:b: 1
      #|a:: 1
      #|http://example.com: 1
      #|"a #b": 1
      #|a#b: 1
      #|"- x": 1
      #|-: 1
      #|-x: 1
      #|"-1": 1
      #|"? x": 1
      #|?: 1
      #|?x: 1
      #|": x": 1
      #|:: 1
      #|:x: 1
      #|"&a": 1
      #|"*a": 1
      #|"!a": 1
      #|"#a": 1
      #|"|": 1
      #|">": 1
      #|"%a": 1
      #|"@a": 1
      #|"`a": 1
      #|"[a]": 1
      #|"{a}": 1
      #|",a": 1
      #|"\"a": 1
      #|"'a": 1
      #|a"b: 1
      #|a'b: 1
      #|---: 1
      #|"--- x": 1
      #|---x: 1
      #|...: 1
      #|"... x": 1
      #|café: 1
      #|日本語: 1
      #|😀: 1
      #|
    ),
  )
  // A document that is one string starts at the start of a line too.
  inspect(written(Json::string("---")), content="\"---\"\n")
  inspect(written(Json::string("...")), content="\"...\"\n")
  inspect(written(Json::string("--- x")), content="\"--- x\"\n")
  inspect(written(Json::string("---x")), content="---x\n")
}

///|
/// Every string of one to three characters from an alphabet of indicators,
/// white space and characters that start numbers, then `quoting_cases`.
fn quoting_corpus() -> Array[String] {
  let alphabet = " :#-?.a0n\"',[{&!|>%@`~<="
  let strings = []
  for c1 in alphabet {
    strings.push(c1.to_string())
    for c2 in alphabet {
      strings.push("\{c1}\{c2}")
      for c3 in alphabet {
        strings.push("\{c1}\{c2}\{c3}")
      }
    }
  }
  strings + quoting_cases
}

///|
/// Whether `text` parses as `expected`.
fn reads_as(text : String, expected : Json) -> Bool {
  try @yaml.parse(text) catch {
    _ => false
  } noraise {
    tree => tree == expected
  }
}

///|
test "a string is written plain exactly when the parser reads it back plain, in each place" {
  for s in quoting_corpus() {
    let value = Json::string(s)
    // A value in a mapping.
    let in_mapping = "k: \{s}\n"
    let tree = Json::object({ "k": value })
    assert_eq(written(tree) == in_mapping, reads_as(in_mapping, tree), msg=s)
    // A document of one string.
    let document = "\{s}\n"
    assert_eq(written(value) == document, reads_as(document, value), msg=s)
    // A key at the start of a line, and a nested one.
    let top_key = "\{s}: 1\n"
    let tree = Json::object(Map::from_array([(s, Json::number(1))]))
    assert_eq(written(tree) == top_key, reads_as(top_key, tree), msg=s)
    let nested_key = "k:\n  \{s}: 1\n"
    let tree = Json::object({ "k": tree })
    assert_eq(written(tree) == nested_key, reads_as(nested_key, tree), msg=s)
  }
}

///|
test "inside double quotes, quotes, backslashes, line breaks, tabs and other control characters are escapes" {
  let strings = [
    "line 1\nline 2", "\ttab", "a\tb", "a\r\nb", "\"q\" \\ back", "\u{0}\u{7}\u{8}\u{b}\u{c}\u{1b}",
    "\u{1}\u{1f}\u{7f}", "\u{80}\u{85}\u{9f}", "\u{2028}\u{2029}", "\u{feff}bom",
    "\u{fffe}\u{ffff}", "😀\n", "\n",
  ]
  let tree = Json::array(strings.map(Json::string))
  let text = written(tree)
  inspect(
    text,
    content=(
      #|- "line 1\nline 2"
      #|- "\ttab"
      #|- "a\tb"
      #|- "a\r\nb"
      #|- "\"q\" \\ back"
      #|- "\0\a\b\v\f\e"
      #|- "\x01\x1F\x7F"
      #|- "\x80\N\x9F"
      #|- "\L\P"
      #|- "\uFEFFbom"
      #|- "\uFFFE\uFFFF"
      #|- "😀\n"
      #|- "\n"
      #|
    ),
  )
  assert_eq(@yaml.parse(text), tree)
  // Keys too.
  let tree = Json::object(Map::from_array(strings.map(s => (s, Json::null()))))
  assert_eq(@yaml.parse(written(tree)), tree)
}

///|
test "numbers read back the same: big integers keep their digits, others take the shortest form" {
  let tree = @json.parse(
    (
      #|{ "big": [9007199254740993, -12345678901234567890123, 1e400],
      #|  "short": [1.50, 1E3, 0.1, 1e21, 5e-324, -0.0, 100, 1.7976931348623157e308, 1.23e-18] }
    ),
  )
  let text = written(tree)
  inspect(
    text,
    content=(
      #|big:
      #|  - 9007199254740993
      #|  - -12345678901234567890123
      #|  - 1e400
      #|short:
      #|  - 1.5
      #|  - 1000
      #|  - 0.1
      #|  - 1e+21
      #|  - 5e-324
      #|  - 0
      #|  - 100
      #|  - 1.7976931348623157e+308
      #|  - 1.23e-18
      #|
    ),
  )
  assert_eq(@yaml.parse(text).stringify(), tree.stringify())
}

///|
test "a number with no text in JSON syntax is an error at its pointer" {
  let nan = 0.0 / 0.0
  let infinity = 1.0 / 0.0
  inspect(
    written(
      Json::object({ "a": Json::array([Json::number(1), Json::number(nan)]) }),
    ),
    content="error /a/1: a number must be finite, or keep the text it was read from",
  )
  inspect(
    written(Json::number(-infinity)),
    content="error : a number must be finite, or keep the text it was read from",
  )
  inspect(
    written(Json::object({ "a~b/c": Json::number(16, repr="0x10") })),
    content="error /a~0b~1c: \"0x10\" is not a number in JSON syntax",
  )
  inspect(written(Json::number(infinity, repr="-1e999")), content="-1e999\n")
}

///|
test "a string with an unpaired surrogate is an error at its pointer" {
  let lone = StringBuilder()
  lone.write_string("a")
  lone.write_char((0xDC00).unsafe_to_char())
  let lone = lone.to_string()
  inspect(
    written(Json::object({ "k": Json::array([Json::string(lone)]) })),
    content="error /k/0: U+DC00 is half of a surrogate pair; UTF-8 cannot hold it alone",
  )
  inspect(
    written(
      Json::object({
        "k": Json::object(Map::from_array([(lone, Json::null())])),
      }),
    ),
    content=(
      $|error /k/\{lone}: U+DC00 is half of a surrogate pair; UTF-8 cannot hold it alone
    ),
  )
}

///|
/// `depth` arrays, or objects with the key `a`, nested around `inner`.
fn nested(depth : Int, inner : Json, objects? : Bool = false) -> Json {
  let mut tree = inner
  for _ in 0..<depth {
    tree = if objects {
      Json::object({ "a": tree })
    } else {
      Json::array([tree])
    }
  }
  tree
}

///|
test "a tree nested deeper than the parser accepts is an error, never written" {
  // The parser accepts 1024 nested collections, empty ones included.
  for objects in [false, true] {
    for inner in [Json::number(1), Json::array([]), Json::object({})] {
      let tree = nested(1023, inner, objects~)
      assert_eq(@yaml.parse(written(tree)), tree)
    }
    let tree = nested(1024, Json::string("x"), objects~)
    assert_eq(@yaml.parse(written(tree)), tree)
  }
  let segments = (segment : String, n : Int) => "/\{segment}".repeat(n)
  inspect(
    written(nested(1025, Json::null())) ==
    "error \{segments("0", 1024)}: nesting is deeper than 1024 levels",
    content="true",
  )
  inspect(
    written(nested(1024, Json::object({}), objects=true)) ==
    "error \{segments("a", 1024)}: nesting is deeper than 1024 levels",
    content="true",
  )
  inspect(
    written(nested(100_000, Json::array([]))) ==
    "error \{segments("0", 1024)}: nesting is deeper than 1024 levels",
    content="true",
  )
}

///|
test "a comment can head the document and precede any item of a sequence" {
  let tree = @json.parse(
    (
      #|{ "version": 1,
      #|  "mocks": [{ "name": "petstore" }],
      #|  "stubs": [
      #|    { "id": "petstore.getPetById.404", "mock": "petstore",
      #|      "request": { "method": "GET", "path": { "pattern": "/v1/pets/[^/]+" },
      #|                   "headers": { "Smock-Status": "404" } },
      #|      "response": { "status": 404, "json": { "message": "Pet not found" } } },
      #|    { "id": "petstore.listPets.200", "mock": "petstore",
      #|      "request": { "method": "GET", "path": "/v1/pets" },
      #|      "response": { "status": 200, "json": [] } } ] }
    ),
  )
  let text = written(
    tree,
    comment=[
      "Generated by smock import-openapi from petstore.yaml", "(Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.",
      "Do not edit: the next import replaces this file.",
    ],
    item_comments={
      "/stubs/0": ["GET /pets/{petId}, 404: Find a pet by ID"],
      "/stubs/1": ["GET /pets, 200: List all pets", "deprecated"],
    },
  )
  inspect(
    text,
    content=(
      #|# Generated by smock import-openapi from petstore.yaml
      #|# (Petstore 1.0.0, OpenAPI 3.1.0), with --mock petstore.
      #|# Do not edit: the next import replaces this file.
      #|version: 1
      #|mocks:
      #|  - name: petstore
      #|stubs:
      #|  # GET /pets/{petId}, 404: Find a pet by ID
      #|  - id: petstore.getPetById.404
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path:
      #|        pattern: /v1/pets/[^/]+
      #|      headers:
      #|        Smock-Status: "404"
      #|    response:
      #|      status: 404
      #|      json:
      #|        message: Pet not found
      #|  # GET /pets, 200: List all pets
      #|  # deprecated
      #|  - id: petstore.listPets.200
      #|    mock: petstore
      #|    request:
      #|      method: GET
      #|      path: /v1/pets
      #|    response:
      #|      status: 200
      #|      json: []
      #|
    ),
  )
  assert_eq(@yaml.parse(text), tree)
}

///|
test "a comment before the first item of a sequence inside a sequence starts the sequence on its own line" {
  let tree = @json.parse("[[[1, 2], 3], {\"a/b\": [4]}, 5]")
  let text = written(tree, comment=["top"], item_comments={
    "/0": ["outer"],
    "/0/0": ["middle"],
    "/0/0/1": ["inner"],
    "/1/a~1b/0": ["escaped"],
    "/2": [],
  })
  inspect(
    text,
    content=(
      #|# top
      #|# outer
      #|-
      #|  # middle
      #|  - - 1
      #|    # inner
      #|    - 2
      #|  - 3
      #|- a/b:
      #|    # escaped
      #|    - 4
      #|- 5
      #|
    ),
  )
  assert_eq(@yaml.parse(text), tree)
  // The pointer of the empty key is `/`.
  inspect(
    written(@json.parse("{\"\": [1]}"), item_comments={ "//0": ["empty key"] }),
    content=(
      #|"":
      #|  # empty key
      #|  - 1
      #|
    ),
  )
}

///|
test "in a comment, control characters and the line breaks of YAML 1.1 become spaces, and trailing spaces are dropped" {
  let lone = StringBuilder()
  lone.write_char((0xD800).unsafe_to_char())
  let text = written(
    Json::array([Json::number(1)]),
    comment=[
      "a\nb\r\nc\td",
      "\u{0}\u{1f}\u{7f}\u{80}\u{85}\u{9f}|",
      "\u{2028}\u{2029}\u{feff}\u{fffe}\u{ffff}|",
      "\{lone.to_string()}|",
      "trailing \t ",
      "",
      "  ",
      "  indented",
      "😀 café",
    ],
    item_comments={ "/0": ["- not an item: \"quoted\" # 'and' {flow}\n- 2"] },
  )
  inspect(
    text,
    content=(
      #|# a b  c d
      #|#       |
      #|#      |
      #|#  |
      #|# trailing
      #|#
      #|#
      #|#   indented
      #|# 😀 café
      #|# - not an item: "quoted" # 'and' {flow} - 2
      #|- 1
      #|
    ),
  )
  assert_eq(@yaml.parse(text), Json::array([Json::number(1)]))
}

///|
test "a comment for a pointer that names no sequence item is an error" {
  let tree = @json.parse("{\"stubs\": [{\"id\": \"a\"}], \"version\": 1}")
  for
    pointer in [
      "/stubs", "/stubs/1", "/version", "/stubs/0/id", "stubs/0", "", "/stubs/00",
    ] {
    inspect(
      written(
        tree,
        item_comments=Map::from_array([("/stubs/0", ["ok"]), (pointer, ["x"])]),
      ) ==
      "error \{pointer}: no sequence item for this comment",
      content="true",
    )
  }
}

///|
/// A random tree, `depth` levels deep at most, with keys and strings from
/// `strings`, numbers as the JSON parser reads them (an integer beyond 2^53
/// and a number beyond the range of a Double keep their text), booleans,
/// null, and empty and nested collections.
fn random_tree(
  rand : @random.Rand,
  depth : Int,
  strings : Array[String],
) -> Json {
  let numbers = [
    "0", "-0", "1", "-7", "1.5", "1.50", "1e3", "-2.5E-7", "0.1", "9007199254740993",
    "-12345678901234567890123", "1e400", "-1e400", "1.7976931348623157e308", "5e-324",
  ]
  let kind = if depth == 0 { rand.int(limit=6) } else { rand.int(limit=10) }
  match kind {
    0 | 1 => Json::string(strings[rand.int(limit=strings.length())])
    2 =>
      @json.parse(numbers[rand.int(limit=numbers.length())]) catch {
        _ => Json::null()
      }
    3 => Json::boolean(rand.boolean())
    4 => Json::null()
    5 => if rand.boolean() { Json::array([]) } else { Json::object({}) }
    6 | 7 => {
      let members = Map([])
      for _ in 0..<(1 + rand.int(limit=4)) {
        members[strings[rand.int(limit=strings.length())]] = random_tree(
          rand,
          depth - 1,
          strings,
        )
      }
      Json::object(members)
    }
    _ =>
      Json::array(
        Array::makei(1 + rand.int(limit=4), _ => {
          random_tree(rand, depth - 1, strings)
        }),
      )
  }
}

///|
/// The JSON Pointer of every item of every sequence in `tree`.
fn item_pointers(tree : Json, pointer : String, out : Array[String]) -> Unit {
  match tree {
    Object(members) =>
      for key, value in members {
        let segment = key
          .replace_all(old="~", new="~0")
          .replace_all(old="/", new="~1")
        item_pointers(value, "\{pointer}/\{segment}", out)
      }
    Array(items) =>
      for i, item in items {
        out.push("\{pointer}/\{i}")
        item_pointers(item, "\{pointer}/\{i}", out)
      }
    _ => ()
  }
}

///|
test "parse(write(v)) is v for generated trees, with comments anywhere" {
  let rand = @random.Rand::chacha8(seed=b"smock yaml writer round trips!!!")
  let strings = quoting_cases +
    [
      "line 1\nline 2", "\ttab", "a\r\nb", "\"q\" \\ back", "\u{0}\u{1b}\u{7f}",
      "\u{85}\u{2028}", "\u{feff}", "~/a", "a/b", "😀", "--- x", "k: v", "- - x",
      "#", "a # b", "2001-12-14 21:59:43.10 -5",
    ]
  let mut items = 0
  for _ in 0..<3000 {
    let tree = random_tree(rand, 6, strings)
    let pointers = []
    item_pointers(tree, "", pointers)
    let item_comments = Map([])
    for pointer in pointers {
      if rand.int(limit=3) == 0 {
        item_comments[pointer] = Array::makei(rand.int(limit=3), _ => {
          strings[rand.int(limit=strings.length())]
        })
      }
    }
    items += item_comments.length()
    let comment = if rand.boolean() {
      ["header", "\n# not a key: 1"]
    } else {
      []
    }
    let text = written(tree, comment~, item_comments~)
    let back = @yaml.parse(text) catch { error => fail("\{error}\n\{text}") }
    assert_eq(back.stringify(), tree.stringify(), msg=text)
    // The same tree gives the same bytes.
    assert_eq(written(tree, comment~, item_comments~), text)
  }
  // Many items had a comment.
  assert_true(items > 1000)
}
