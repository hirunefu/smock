///|
/// Parses `text` and renders the tree as compact JSON, or the error as
/// `error <pointer>: <message>`.
fn yaml(text : String) -> String {
  try @yaml.parse(text) catch {
    @yaml.ParseError(pointer~, message~) => "error \{pointer}: \{message}"
  } noraise {
    tree => tree.stringify()
  }
}

///|
test "a block mapping of plain scalars is an object of strings, nested by indentation" {
  inspect(
    yaml(
      (
        #|name: users
        #|request:
        #|  method: GET
        #|  path: /users/1
        #|response:
        #|  headers:
        #|    Content-Type: application/json
        #|  body: hello world
      ),
    ),
    content=(
      #|{"name":"users","request":{"method":"GET","path":"/users/1"},"response":{"headers":{"Content-Type":"application/json"},"body":"hello world"}}
    ),
  )
}

///|
test "a block sequence is an array; its items may be compact mappings or sequences" {
  inspect(
    yaml(
      (
        #|mocks:
        #|  - users
        #|  - orders
        #|stubs:
        #|- id: a
        #|  mock: users
        #|  hosts:
        #|  - a.example
        #|- id: b
        #|-   - x
        #|    - - v
        #|      - w
        #|-
        #|  nested: value
      ),
    ),
    content=(
      #|{"mocks":["users","orders"],"stubs":[{"id":"a","mock":"users","hosts":["a.example"]},{"id":"b"},["x",["v","w"]],{"nested":"value"}]}
    ),
  )
  inspect(yaml("- a\n- b\n"), content="[\"a\",\"b\"]")
}

///|
test "plain true, false, null and JSON-syntax numbers are typed, as the JSON parser types them" {
  let typed =
    #|- true
    #|- false
    #|- null
    #|- 0
    #|- -0
    #|- 200
    #|- -17
    #|- 1.5
    #|- -0.25
    #|- 1e3
    #|- 2.5E-3
    #|- 1e+2
    #|- 12345678901234567890
  guard @yaml.parse(typed) is Array(items) else { fail("not an array") }
  let json = @json.parse(
    "[true, false, null, 0, -0, 200, -17, 1.5, -0.25, 1e3, 2.5E-3, 1e+2, 12345678901234567890]",
  )
  guard json is Array(expected) else { fail("not an array") }
  for i, item in items {
    assert_eq(item, expected[i])
  }
  debug_inspect(
    items,
    content=(
      #|[
      #|  True,
      #|  False,
      #|  Null,
      #|  Number(0),
      #|  Number(0),
      #|  Number(200),
      #|  Number(-17),
      #|  Number(1.5),
      #|  Number(-0.25),
      #|  Number(1000),
      #|  Number(0.0025),
      #|  Number(100),
      #|  Number(12345678901234567000, repr=Some("12345678901234567890")),
      #|]
    ),
  )
}

///|
test "quoted scalars are always strings, as values and as keys" {
  inspect(
    yaml(
      (
        #|"true": 'false'
        #|'200': "null"
        #|"1.5": '1e3'
        #|'yes': "yes"
        #|empty: ''
        #|"": empty key
      ),
    ),
    content=(
      #|{"true":"false","200":"null","1.5":"1e3","yes":"yes","empty":"","":"empty key"}
    ),
  )
}

///|
test "a single-quoted scalar escapes a quote by doubling it" {
  inspect(
    yaml(
      (
        #|- 'it''s'
        #|- 'a\nb # not a comment: "x"'
      ),
    ),
    content=(
      #|["it's","a\\nb # not a comment: \"x\""]
    ),
  )
}

///|
test "a double-quoted scalar has the escapes of JSON and YAML" {
  inspect(
    yaml(
      (
        #|- "q\" b\\ s\/ n\n t\t r\r b\b f\f"
        #|- "0\0 a\a v\v e\e sp\  tab\	"
        #|- "x\x41 ué U\U0001F600 pair😀"
      ),
    ),
    content=(
      #|["q\" b\\ s/ n\n t\t r\r b\b f\f","0\u0000 a\u0007 v\u000b e\u001b sp  tab\t","xA ué U😀 pair😀"]
    ),
  )
  // JSON output shows these characters raw, so compare code points.
  let separators =
    #|"N\N _\_ L\L P\P"
  assert_eq(
    @yaml.parse(separators),
    Json::string("N\u{85} _\u{a0} L\u{2028} P\u{2029}"),
  )
}

///|
test "quoted scalars fold line breaks: one becomes a space, each empty line a newline" {
  inspect(
    yaml(
      (
        #|single: 'a
        #|   b
        #|
        #|   c'
        #|double: "a
        #|  b
        #|
        #|
        #|  c \
        #|    d\
        #|  e"
      ),
    ),
    content=(
      #|{"single":"a b\nc","double":"a b\n\nc de"}
    ),
  )
}

///|
test "comments run from a # after white space to the end of the line" {
  inspect(
    yaml(
      (
        #|# A comment before the document.
        #|request: # a comment after a key
        #|  # a comment line inside a mapping
        #|    # indented differently
        #|  method: GET # a comment after a value
        #|  path: /a#b
        #|  "x#y": 'quoted # not a comment' # a comment
        #|list:
        #|  - a   # spaces before a comment
        #|
        #|  # a comment between items
        #|  - b
        #|# A comment after the document.
      ),
    ),
    content=(
      #|{"request":{"method":"GET","path":"/a#b","x#y":"quoted # not a comment"},"list":["a","b"]}
    ),
  )
  // "Comments must be separated from other tokens by white space
  // characters" (YAML 1.2.2, section 6.6). A `#` right after a quoted
  // scalar, a flow collection, a flow indicator or a block scalar's header
  // starts no comment, so the text is refused: yaml-test-suite marks the
  // first three inputs, SU5Z, 9JBA and CVW2, as errors. `parse` documents
  // the message: "anywhere else, such as right after a quoted value or a
  // flow collection, it is rejected with 'a comment needs a space before
  // its #'", words that the maintainer approved on 2026-11-18 (#366). The
  // pointer is the deepest node reached, as `ParseError` documents. The nearest inputs that stay valid follow: a `#` after a
  // space or a tab, which section 6.6 allows, and a `#` inside a plain
  // scalar, which section 7.3.3 allows after a character that is not white
  // space ("An ns-char preceding").
  inspect(
    each([
      "key: \"value\"# invalid comment", "---\n[ a, b, c, ]#invalid\n", "---\n[ a, b, c,#invalid\n]\n",
      "a: 'x'#c", "a: {b: 1}#c", "[a, \"b\"#c\n]", "{a: \"b\"#c\n}", "[#c\n a]",
      "a: |#c\n  x\n", "a: >-#c\n  x\n", "a: 1\n\"b\"#c: 2", "key: \"value\" # c",
      "key: \"value\"\t# c", "a: [x]\t# c", "{a: \"b\" # c\n}", "a: | # c\n  x\n",
      "key: value# c", "[a#b, c]",
    ]),
    content=(
      #|"key: \"value\"# invalid comment" -> error /key: a comment needs a space before its #
      #|"---\n[ a, b, c, ]#invalid\n" -> error /2: a comment needs a space before its #
      #|"---\n[ a, b, c,#invalid\n]\n" -> error /2: a comment needs a space before its #
      #|"a: 'x'#c" -> error /a: a comment needs a space before its #
      #|"a: {b: 1}#c" -> error /a/b: a comment needs a space before its #
      #|"[a, \"b\"#c\n]" -> error /1: a comment needs a space before its #
      #|"{a: \"b\"#c\n}" -> error /a: a comment needs a space before its #
      #|"[#c\n a]" -> error : a comment needs a space before its #
      #|"a: |#c\n  x\n" -> error /a: a comment needs a space before its #
      #|"a: >-#c\n  x\n" -> error /a: a comment needs a space before its #
      #|"a: 1\n\"b\"#c: 2" -> error /a: a comment needs a space before its #
      #|"key: \"value\" # c" -> {"key":"value"}
      #|"key: \"value\"\t# c" -> {"key":"value"}
      #|"a: [x]\t# c" -> {"a":["x"]}
      #|"{a: \"b\" # c\n}" -> {"a":"b"}
      #|"a: | # c\n  x\n" -> {"a":"x\n"}
      #|"key: value# c" -> {"key":"value# c"}
      #|"[a#b, c]" -> ["a#b","c"]
    ),
  )
}

///|
test "a plain scalar continues on more indented lines, folded like a quoted one" {
  inspect(
    yaml(
      (
        #|folded: first
        #|  second
        #|
        #|    third
        #|list:
        #|  - a
        #|   b
        #|  - c # a comment ends it
        #|  - d
      ),
    ),
    content=(
      #|{"folded":"first second\nthird","list":["a b","c","d"]}
    ),
  )
}

///|
test "a literal block scalar keeps its lines; chomping decides the final line breaks" {
  inspect(
    yaml(
      (
        #|literal: | # a comment in the header
        #|  line 1
        #|    indented # not a comment
        #|  line 3
        #|
        #|clip: |
        #|  a
        #|
        #|  b
        #|
        #|
        #|strip: |-
        #|  a
        #|
        #|keep: |+
        #|  a
        #|
        #|
        #|empty: |
        #|list:
        #|- |
        #| item
        #|- |-
        #|   item
        #|last: |
        #|  no line break at the end
      ),
    ),
    content=(
      #|{"literal":"line 1\n  indented # not a comment\nline 3\n","clip":"a\n\nb\n","strip":"a","keep":"a\n\n\n","empty":"","list":["item\n","item"],"last":"no line break at the end"}
    ),
  )
  // "A block scalar whose last line ends the text without a line break
  // gets no line break added, as YAML 1.2.2 says (section 8.1.1.2), with
  // each chomping indicator" (`parse`): the last line break of a clipped or
  // kept scalar may be the end of the input (`b-chomped-last`, production
  // 165). Each input comes without and then with a final line break, which
  // a clipped or kept scalar keeps (Example 8.4). The first pair holds a
  // last line of one space, after the indentation; the last, a tab there,
  // which is text. yaml-test-suite reads a line break at the end of the
  // first input, L24T/01, which its lists keep as a known difference.
  inspect(
    each([
      "foo: |\n  x\n   ", "foo: |\n  x\n   \n", "a: |\n  x", "a: |\n  x\n", "a: |-\n  x",
      "a: |-\n  x\n", "a: |+\n  x", "a: |+\n  x\n", "a: >\n  x\n  y", "a: >\n  x\n  y\n",
      "a: |\n \t", "a: |\n \t\n",
    ]),
    content=(
      #|"foo: |\n  x\n   " -> {"foo":"x\n "}
      #|"foo: |\n  x\n   \n" -> {"foo":"x\n \n"}
      #|"a: |\n  x" -> {"a":"x"}
      #|"a: |\n  x\n" -> {"a":"x\n"}
      #|"a: |-\n  x" -> {"a":"x"}
      #|"a: |-\n  x\n" -> {"a":"x"}
      #|"a: |+\n  x" -> {"a":"x"}
      #|"a: |+\n  x\n" -> {"a":"x\n"}
      #|"a: >\n  x\n  y" -> {"a":"x y"}
      #|"a: >\n  x\n  y\n" -> {"a":"x y\n"}
      #|"a: |\n \t" -> {"a":"\t"}
      #|"a: |\n \t\n" -> {"a":"\t\n"}
    ),
  )
  // The same rule for a scalar of empty lines only, kept: with no line
  // break after its last line of spaces, that line is no empty line
  // (`l-empty` ends with a line break, section 6.4), so the scalar is
  // empty. yaml-test-suite reads a line break for the first input, JEF9/02,
  // which its lists keep as a known difference.
  inspect(
    each(["- |+\n   ", "- |+\n   \n"]),
    content=(
      #|"- |+\n   " -> [""]
      #|"- |+\n   \n" -> ["\n"]
    ),
  )
}

///|
test "a folded block scalar joins lines with a space, except around empty and more indented lines" {
  inspect(
    yaml(
      (
        #|folded: >
        #|  one
        #|  two
        #|
        #|  three
        #|    more indented
        #|  four
        #|
        #|strip: >-
        #|  a
        #|  b
        #|keep: >+
        #|  a
        #|
        #|end: x
      ),
    ),
    content=(
      #|{"folded":"one two\nthree\n  more indented\nfour\n","strip":"a b","keep":"a\n\n","end":"x"}
    ),
  )
}

///|
test "flow collections are arrays and objects, and may span lines" {
  inspect(
    yaml(
      (
        #|hosts: [a.example, "b.example", 'c', http://d.example:80/x]
        #|empty: []
        #|object: {a: 1, "b": two, 'c': [x, {d: null}], e f: g h, }
        #|json: {"id":1,"name":"Alice","tags":["x","y"],"ok":true}
        #|lines: [
        #|  one,
        #|  two
        #|    words, # a comment
        #|
        #|  "three"
        #|]
        #|nested: [[1, 2], [], {}]
        #|items:
        #|- [a]
        #|- {b: c}
      ),
    ),
    content=(
      #|{"hosts":["a.example","b.example","c","http://d.example:80/x"],"empty":[],"object":{"a":1,"b":"two","c":["x",{"d":null}],"e f":"g h"},"json":{"id":1,"name":"Alice","tags":["x","y"],"ok":true},"lines":["one","two words","three"],"nested":[[1,2],[],{}],"items":[["a"],{"b":"c"}]}
    ),
  )
  inspect(yaml("[1, two]"), content="[1,\"two\"]")
  inspect(yaml("{a: b}\n"), content="{\"a\":\"b\"}")
}

///|
/// Renders `yaml` for each case, one per line.
fn each(cases : Array[String]) -> String {
  cases.map(text => "\{text.escape()} -> \{yaml(text)}").join("\n")
}

///|
test "anchors, aliases, tags, merge keys, duplicate keys and multiple documents are rejected, each by name" {
  inspect(
    each([
      "a: &x 1", "a: *x", "hosts: [*.example.com]", "a: !!str 1", "- !local x", "&x a: 1",
      "{a: [&x 1]}", "base: {a: 1}\nmerged:\n  <<: {b: 2}", "{<<: {a: 1}}", "a: 1\nb: 2\na: 3",
      "- {a: 1, a: 2}", "a: 1\n---\nb: 2", "---\na: 1\n...\n---\nb: 2", "a: 1\n...\nb: 2",
      "%YAML 1.2\n---\na: 1",
    ]),
    content=(
      #|"a: &x 1" -> error /a: anchors (&) are not supported; quote the value if it is text
      #|"a: *x" -> error /a: aliases (*) are not supported; quote the value if it is text
      #|"hosts: [*.example.com]" -> error /hosts/0: aliases (*) are not supported; quote the value if it is text
      #|"a: !!str 1" -> error /a: tags (!) are not supported; quote the value if it is text
      #|"- !local x" -> error /0: tags (!) are not supported; quote the value if it is text
      #|"&x a: 1" -> error : anchors (&) are not supported; quote the value if it is text
      #|"{a: [&x 1]}" -> error /a/0: anchors (&) are not supported; quote the value if it is text
      #|"base: {a: 1}\nmerged:\n  <<: {b: 2}" -> error /merged/<<: merge keys (<<) are not supported
      #|"{<<: {a: 1}}" -> error /<<: merge keys (<<) are not supported
      #|"a: 1\nb: 2\na: 3" -> error /a: duplicate key
      #|"- {a: 1, a: 2}" -> error /0/a: duplicate key
      #|"a: 1\n---\nb: 2" -> error : multiple documents are not supported
      #|"---\na: 1\n...\n---\nb: 2" -> error : multiple documents are not supported
      #|"a: 1\n...\nb: 2" -> error : multiple documents are not supported
      #|"%YAML 1.2\n---\na: 1" -> error : directives (%) are not supported
    ),
  )
  // Two `---` markers with nothing but white space and comments between
  // them start two documents, the first of them empty: "Since the existence
  // of the document is indicated by this marker, the document itself may be
  // completely empty" (YAML 1.2.2, section 9.1.4). yaml-test-suite's 6XDY,
  // `---\n---\n`, reads as two documents. The documents reject them as
  // multiple documents ("Anchors, aliases, tags, merge keys, duplicate keys
  // and multiple documents are rejected", docs/definition-files.md, Writing
  // Definition files in YAML), with the message above for multiple documents.
  inspect(
    each([
      "---\n---\n", "---\n---", "--- # a comment\n\n# another\n---\na: 1", "---\n--- x",
    ]),
    content=(
      #|"---\n---\n" -> error : multiple documents are not supported
      #|"---\n---" -> error : multiple documents are not supported
      #|"--- # a comment\n\n# another\n---\na: 1" -> error : multiple documents are not supported
      #|"---\n--- x" -> error : multiple documents are not supported
    ),
  )
}

///|
test "one document may start with --- and end with ..." {
  inspect(
    each([
      "---\na: 1\n", "--- # a comment\na: 1\n...\n# a comment after the end\n", "--- [1]",
      "--- |\n  text\n", "--- \"text\"\n...",
    ]),
    content=(
      #|"---\na: 1\n" -> {"a":1}
      #|"--- # a comment\na: 1\n...\n# a comment after the end\n" -> {"a":1}
      #|"--- [1]" -> [1]
      #|"--- |\n  text\n" -> "text\n"
      #|"--- \"text\"\n..." -> "text"
    ),
  )
}

///|
/// Parses `value` as the value of key `a` and renders the result.
fn as_value(values : Array[String]) -> String {
  values.map(value => "\{value} -> \{yaml("a: \{value}")}").join("\n")
}

///|
test "booleans of YAML 1.1 and non-lowercase booleans and nulls must be quoted" {
  inspect(
    as_value([
      "yes", "Yes", "YES", "yEs", "no", "No", "NO", "on", "On", "ON", "off", "Off",
      "OFF", "y", "Y", "n", "N", "True", "TRUE", "tRUE", "False", "FALSE", "~", "Null",
      "NULL", "nULL",
    ]),
    content=(
      #|yes -> error /a: "yes" may be read as a boolean; quote this value
      #|Yes -> error /a: "Yes" may be read as a boolean; quote this value
      #|YES -> error /a: "YES" may be read as a boolean; quote this value
      #|yEs -> error /a: "yEs" may be read as a boolean; quote this value
      #|no -> error /a: "no" may be read as a boolean; quote this value
      #|No -> error /a: "No" may be read as a boolean; quote this value
      #|NO -> error /a: "NO" may be read as a boolean; quote this value
      #|on -> error /a: "on" may be read as a boolean; quote this value
      #|On -> error /a: "On" may be read as a boolean; quote this value
      #|ON -> error /a: "ON" may be read as a boolean; quote this value
      #|off -> error /a: "off" may be read as a boolean; quote this value
      #|Off -> error /a: "Off" may be read as a boolean; quote this value
      #|OFF -> error /a: "OFF" may be read as a boolean; quote this value
      #|y -> error /a: "y" may be read as a boolean; quote this value
      #|Y -> error /a: "Y" may be read as a boolean; quote this value
      #|n -> error /a: "n" may be read as a boolean; quote this value
      #|N -> error /a: "N" may be read as a boolean; quote this value
      #|True -> error /a: "True" may be read as a boolean; quote this value
      #|TRUE -> error /a: "TRUE" may be read as a boolean; quote this value
      #|tRUE -> error /a: "tRUE" may be read as a boolean; quote this value
      #|False -> error /a: "False" may be read as a boolean; quote this value
      #|FALSE -> error /a: "FALSE" may be read as a boolean; quote this value
      #|~ -> error /a: "~" may be read as null; quote this value
      #|Null -> error /a: "Null" may be read as null; quote this value
      #|NULL -> error /a: "NULL" may be read as null; quote this value
      #|nULL -> error /a: "nULL" may be read as null; quote this value
    ),
  )
}

///|
test "numbers that are not in JSON syntax must be quoted" {
  inspect(
    as_value([
      "0x1F", "0x_1f", "-0x1F", "0o17", "007", "-012", "08", "09.5", "00.5", "1_000",
      "1_000.5", "0b1010", "+1", "+1.5", ".5", "-.5", "1.", "1.e3", "1.5e3_0", "1.2.3",
      ".inf", "-.inf", "+.Inf", ".INF", ".nan", ".NaN", ".NAN", "190:20:30", "1:30",
      "-1:30", "190:20:30.15",
    ]),
    content=(
      #|0x1F -> error /a: "0x1F" may be read as a number; quote this value
      #|0x_1f -> error /a: "0x_1f" may be read as a number; quote this value
      #|-0x1F -> error /a: "-0x1F" may be read as a number; quote this value
      #|0o17 -> error /a: "0o17" may be read as a number; quote this value
      #|007 -> error /a: "007" may be read as a number; quote this value
      #|-012 -> error /a: "-012" may be read as a number; quote this value
      #|08 -> error /a: "08" may be read as a number; quote this value
      #|09.5 -> error /a: "09.5" may be read as a number; quote this value
      #|00.5 -> error /a: "00.5" may be read as a number; quote this value
      #|1_000 -> error /a: "1_000" may be read as a number; quote this value
      #|1_000.5 -> error /a: "1_000.5" may be read as a number; quote this value
      #|0b1010 -> error /a: "0b1010" may be read as a number; quote this value
      #|+1 -> error /a: "+1" may be read as a number; quote this value
      #|+1.5 -> error /a: "+1.5" may be read as a number; quote this value
      #|.5 -> error /a: ".5" may be read as a number; quote this value
      #|-.5 -> error /a: "-.5" may be read as a number; quote this value
      #|1. -> error /a: "1." may be read as a number; quote this value
      #|1.e3 -> error /a: "1.e3" may be read as a number; quote this value
      #|1.5e3_0 -> {"a":"1.5e3_0"}
      #|1.2.3 -> error /a: "1.2.3" may be read as a number; quote this value
      #|.inf -> error /a: ".inf" may be read as a number; quote this value
      #|-.inf -> error /a: "-.inf" may be read as a number; quote this value
      #|+.Inf -> error /a: "+.Inf" may be read as a number; quote this value
      #|.INF -> error /a: ".INF" may be read as a number; quote this value
      #|.nan -> error /a: ".nan" may be read as a number; quote this value
      #|.NaN -> error /a: ".NaN" may be read as a number; quote this value
      #|.NAN -> error /a: ".NAN" may be read as a number; quote this value
      #|190:20:30 -> error /a: "190:20:30" may be read as a number; quote this value
      #|1:30 -> error /a: "1:30" may be read as a number; quote this value
      #|-1:30 -> error /a: "-1:30" may be read as a number; quote this value
      #|190:20:30.15 -> error /a: "190:20:30.15" may be read as a number; quote this value
    ),
  )
}

///|
test "timestamps and the YAML 1.1 merge and value keys must be quoted" {
  inspect(
    as_value([
      "2001-12-14", "2001-12-14t21:59:43.10-05:00", "2001-12-14 21:59:43.10 -5",
      "2001-1-4 1:59:43", "2001-12-14T21:59:43Z", "2001-12-14 21:59:43 Z", "<<",
      "=",
    ]),
    content=(
      #|2001-12-14 -> error /a: "2001-12-14" may be read as a timestamp; quote this value
      #|2001-12-14t21:59:43.10-05:00 -> error /a: "2001-12-14t21:59:43.10-05:00" may be read as a timestamp; quote this value
      #|2001-12-14 21:59:43.10 -5 -> error /a: "2001-12-14 21:59:43.10 -5" may be read as a timestamp; quote this value
      #|2001-1-4 1:59:43 -> error /a: "2001-1-4 1:59:43" may be read as a timestamp; quote this value
      #|2001-12-14T21:59:43Z -> error /a: "2001-12-14T21:59:43Z" may be read as a timestamp; quote this value
      #|2001-12-14 21:59:43 Z -> error /a: "2001-12-14 21:59:43 Z" may be read as a timestamp; quote this value
      #|<< -> error /a: "<<" may be read as a merge key; quote this value
      #|= -> error /a: "=" may be read as a value key; quote this value
    ),
  )
}

///|
test "the same values quoted are strings, and look-alikes that no YAML version types are strings too" {
  inspect(
    as_value([
      "'yes'", "\"0x1F\"", "'2001-12-14'", "\"~\"", "yes!", "0X1F", "0xG", ".infinity",
      "1:60", "2001-12-14x", "1_", "-", "<<<", "==", "1e3_0",
    ]),
    content=(
      #|'yes' -> {"a":"yes"}
      #|"0x1F" -> {"a":"0x1F"}
      #|'2001-12-14' -> {"a":"2001-12-14"}
      #|"~" -> {"a":"~"}
      #|yes! -> {"a":"yes!"}
      #|0X1F -> {"a":"0X1F"}
      #|0xG -> {"a":"0xG"}
      #|.infinity -> {"a":".infinity"}
      #|1:60 -> {"a":"1:60"}
      #|2001-12-14x -> {"a":"2001-12-14x"}
      #|1_ -> error /a: "1_" may be read as a number; quote this value
      #|- -> error /a: a block sequence must start on its own line
      #|<<< -> {"a":"<<<"}
      #|== -> {"a":"=="}
      #|1e3_0 -> {"a":"1e3_0"}
    ),
  )
  // Near misses of the YAML 1.1 int, float and timestamp types
  // (yaml.org/type/int.html, float.html and timestamp.html): the digits of
  // an integer or a float start with a digit, not `_`, and an exponent
  // needs a digit after its sign; a date without a time has a two-digit
  // month and day, a month or day has at most two digits, and a time has
  // an hour and a two-digit second. `1.x` is not a JSON number either,
  // whose point needs a digit after it (RFC 8259, section 6). No YAML
  // version types them, so each is a string, as docs/definition-files.md
  // says of every other plain scalar.
  inspect(
    as_value([
      "_1", "_1.5", "1.5e+", "1.x", "2001-1-14", "2001-123-14", "2001-12-14T:59:43",
      "2001-12-14 21:59:4x",
    ]),
    content=(
      #|_1 -> {"a":"_1"}
      #|_1.5 -> {"a":"_1.5"}
      #|1.5e+ -> {"a":"1.5e+"}
      #|1.x -> {"a":"1.x"}
      #|2001-1-14 -> {"a":"2001-1-14"}
      #|2001-123-14 -> {"a":"2001-123-14"}
      #|2001-12-14T:59:43 -> {"a":"2001-12-14T:59:43"}
      #|2001-12-14 21:59:4x -> {"a":"2001-12-14 21:59:4x"}
    ),
  )
}

///|
test "a plain key that is not a string in every YAML version must be quoted" {
  inspect(
    each([
      "on: x", "200: x", "true: x", "null: x", "~: x", "{yes: 1}", "'on': x",
    ]),
    content=(
      #|"on: x" -> error /on: "on" may be read as a boolean; quote this key
      #|"200: x" -> error /200: "200" is read as a number; quote this key
      #|"true: x" -> error /true: "true" is read as a boolean; quote this key
      #|"null: x" -> error /null: "null" is read as null; quote this key
      #|"~: x" -> error /~0: "~" may be read as null; quote this key
      #|"{yes: 1}" -> error /yes: "yes" may be read as a boolean; quote this key
      #|"'on': x" -> {"on":"x"}
    ),
  )
}

///|
test "malformed indentation gives an error at the deepest node reached, or a value when YAML reads one" {
  inspect(
    each([
      "a:\n  b: 1\n c: 2", "a:\n    b: 1\n  c: 2", "stubs:\n  - id: a\n     mock: m",
      "a: 1\n  b: 2", "a: b: c", "a: - b", "a: 1\nb", "- a\nb: 1", "  a: 1\nb: 2",
      "a:\n- b\n  - c", "- a\n - b", "a: [1]\n  b: 2", "a: |\n    \n  x", "a: |\n  \n  x",
    ]),
    content=(
      #|"a:\n  b: 1\n c: 2" -> error /a/b: bad indentation
      #|"a:\n    b: 1\n  c: 2" -> error /a/b: bad indentation
      #|"stubs:\n  - id: a\n     mock: m" -> error /stubs/0/id: unexpected ':' after a value; a nested mapping must start on its own line
      #|"a: 1\n  b: 2" -> error /a: unexpected ':' after a value; a nested mapping must start on its own line
      #|"a: b: c" -> error /a: unexpected ':' after a value; a nested mapping must start on its own line
      #|"a: - b" -> error /a: a block sequence must start on its own line
      #|"a: 1\nb" -> error /a: expected a key followed by ':'
      #|"- a\nb: 1" -> error /0: unexpected content; check the indentation
      #|"  a: 1\nb: 2" -> error /a: unexpected content; check the indentation
      #|"a:\n- b\n  - c" -> {"a":["b - c"]}
      #|"- a\n - b" -> ["a - b"]
      #|"a: [1]\n  b: 2" -> error /a/0: bad indentation
      #|"a: |\n    \n  x" -> error /a: a leading empty line of a block scalar has more spaces than its first line
      #|"a: |\n  \n  x" -> {"a":"\nx"}
    ),
  )
  // A sequence item where the mapping expects its next key, and a key
  // continued on a more indented line: YAML limits an implicit key to a
  // single line (YAML 1.2.2, section 8.2.2). The messages are those
  // #280's acceptance criteria name. The first pointer is the deepest node
  // reached; the second names the member by its folded key, as
  // `ParseError` documents: "A key written over several lines, which YAML
  // allows only on one line, names the member by its text with the lines
  // folded, as a scalar over several lines is read: `a\n b: 1` gives
  // `/a b`." The line break folds into a space (YAML 1.2.2, section 6.5),
  // and the maintainer confirmed that pointer on 2026-11-17 (#275).
  inspect(
    each(["a: 1\n- b", "a\n b: 1"]),
    content=(
      #|"a: 1\n- b" -> error /a: expected a key, found a sequence item; check the indentation
      #|"a\n b: 1" -> error /a b: a key must be on a single line
    ),
  )
}

///|
test "tabs in indentation give an error; tabs elsewhere are white space" {
  inspect(
    each([
      "a:\n\tb: 1", "a:\n  \tb: 1", "- a\n\t- b", "a: |\n\tx", "a:\tb", "a: [1,\t2]",
      "a: 1\t# comment", "\t\n# comment\na: 1", "a: |\n  x\ty\n",
    ]),
    content=(
      #|"a:\n\tb: 1" -> error /a: tabs are not allowed in indentation
      #|"a:\n  \tb: 1" -> error /a: tabs are not allowed in indentation
      #|"- a\n\t- b" -> error /0: tabs are not allowed in indentation
      #|"a: |\n\tx" -> error /a: tabs are not allowed in indentation
      #|"a:\tb" -> {"a":"b"}
      #|"a: [1,\t2]" -> {"a":[1,2]}
      #|"a: 1\t# comment" -> {"a":1}
      #|"\t\n# comment\na: 1" -> {"a":1}
      #|"a: |\n  x\ty\n" -> {"a":"x\ty\n"}
    ),
  )
  // In a nested sequence that starts on its parent's `-` line, "both the
  // "-" indicator and the following spaces are considered to be part of the
  // indentation of the nested collection" (YAML 1.2.2, section 8.2.1), and
  // "tab characters must not be used in indentation" (section 6.1). So a
  // tab between two `-` indicators is a tab in indentation, which `parse`
  // rejects ("tabs in indentation"), with the message above.
  // yaml-test-suite marks the first two inputs, Y79Y/004 and Y79Y/005, as
  // errors. A tab between `-` and a scalar separates them and indents
  // nothing: the suite reads `-\t-1` as [-1] (Y79Y/010) and `-\tbaz` as
  // "baz" (6BCT, YAML 1.2.2's Example 6.3).
  inspect(
    each(["-\t-\n", "- \t-\n", "-\t- x", "- -\t- x", "-\t-1\n", "-\tbaz"]),
    content=(
      #|"-\t-\n" -> error /0: tabs are not allowed in indentation
      #|"- \t-\n" -> error /0: tabs are not allowed in indentation
      #|"-\t- x" -> error /0: tabs are not allowed in indentation
      #|"- -\t- x" -> error /0/0: tabs are not allowed in indentation
      #|"-\t-1\n" -> [-1]
      #|"-\tbaz" -> ["baz"]
    ),
  )
  // The same holds for a compact mapping that starts on its sequence's `-`
  // line: "The compact notation may be used when the entry is itself a
  // nested block collection. In this case, both the "-" indicator and the
  // following spaces are considered to be part of the indentation of the
  // nested collection" (YAML 1.2.2, section 8.2.1), so a tab there is a tab
  // in indentation (section 6.1), with the message above, whatever the
  // key's style and however deep the sequence. No case of yaml-test-suite
  // has it (#382). The nearest inputs that stay valid follow: a tab
  // between `-` and a scalar, a flow collection or a block scalar, which
  // separates them (`s-l+block-node`, section 8.2.3; "such white space may
  // safely include tab characters", section 6.2), spaces before a compact
  // mapping, and a tab after a key's `:`.
  inspect(
    each([
      "-\ta: 1", "- \ta: 1", "stubs:\n-\tid: a\n  mock: m", "-\t\"a\": 1", "- -\ta: 1",
      "-\tx", "-\t[a, b]", "-\t|\n  x\n", "-  a: 1", "stubs:\n-   id: a\n    mock: m",
      "- a:\tb",
    ]),
    content=(
      #|"-\ta: 1" -> error /0: tabs are not allowed in indentation
      #|"- \ta: 1" -> error /0: tabs are not allowed in indentation
      #|"stubs:\n-\tid: a\n  mock: m" -> error /stubs/0: tabs are not allowed in indentation
      #|"-\t\"a\": 1" -> error /0: tabs are not allowed in indentation
      #|"- -\ta: 1" -> error /0/0: tabs are not allowed in indentation
      #|"-\tx" -> ["x"]
      #|"-\t[a, b]" -> [["a","b"]]
      #|"-\t|\n  x\n" -> ["x\n"]
      #|"-  a: 1" -> [{"a":1}]
      #|"stubs:\n-   id: a\n    mock: m" -> {"stubs":[{"id":"a","mock":"m"}]}
      #|"- a:\tb" -> [{"a":"b"}]
    ),
  )
  // In a block scalar, only spaces indent. "The content indentation level
  // is equal to the number of leading spaces on the first non-empty line"
  // (YAML 1.2.2, section 8.1.1.1), and a line of text is that many spaces
  // and then any characters (`s-indent(n) nb-char+`, section 8.1.2), so a
  // tab after them is text, as the last item of Example 8.2 shows. An empty
  // line is spaces, as many as the indentation or fewer, and then the line
  // break (`l-empty`, section 6.4). A tab after fewer spaces than the
  // indentation is in neither, so when the document goes on after that
  // line, `parse` rejects the tab as a tab in indentation, with the message
  // above. yaml-test-suite reads the first input, Y79Y/001, as
  // {"foo": "\t\n", "bar": 1}, and marks the second, Y79Y/000, as an
  // error. "It is an error for any of the leading empty lines to contain
  // more spaces than the first non-empty line" (section 8.1.1.1): the
  // message is the one the test above gives for that. The nearest inputs
  // that stay valid follow: a tab after the indentation once it is known,
  // and a line of fewer spaces with no tab, which is an empty line.
  inspect(
    each([
      "foo: |\n \t\nbar: 1", "foo: |\n\t\nbar: 1", "- >\n \t\n detected\n", "a: |\n  \t\n  x\n",
      "a: |\n \n  \t\n", "a: |\n   \n \t\n", "a: |\n  x\n \t\n  y\n", "a: |\n  x\n\t\nb: 1",
      "a: |\n  x\n  \t\n", "a: |\n  x\n \n  y\n",
    ]),
    content=(
      #|"foo: |\n \t\nbar: 1" -> {"foo":"\t\n","bar":1}
      #|"foo: |\n\t\nbar: 1" -> error /foo: tabs are not allowed in indentation
      #|"- >\n \t\n detected\n" -> ["\t\ndetected\n"]
      #|"a: |\n  \t\n  x\n" -> {"a":"\t\nx\n"}
      #|"a: |\n \n  \t\n" -> {"a":"\n\t\n"}
      #|"a: |\n   \n \t\n" -> error /a: a leading empty line of a block scalar has more spaces than its first line
      #|"a: |\n  x\n \t\n  y\n" -> error /a: tabs are not allowed in indentation
      #|"a: |\n  x\n\t\nb: 1" -> error /a: tabs are not allowed in indentation
      #|"a: |\n  x\n  \t\n" -> {"a":"x\n\t\n"}
      #|"a: |\n  x\n \n  y\n" -> {"a":"x\n\ny\n"}
    ),
  )
  // At the end of the text, YAML 1.2.2 reads the same line as a comment
  // line after the document (`l-comment` in `l-yaml-stream`, production
  // 211), but `parse` rejects it there too, with the message above, as
  // libyaml and PyYAML do. The maintainer decided so on 2026-11-18 (#369),
  // and `parse`'s documentation lists it among the valid YAML rejected on
  // purpose: "a line of white space whose tab comes before a block
  // scalar's indentation, with nothing after it but empty lines, comments
  // and the `...` that may end the document". No case of yaml-test-suite
  // has it. The nearest inputs that stay valid follow: a last line of
  // spaces only, which is an empty line, and such a line after a comment
  // that ends the scalar, which YAML reads as a comment line after the
  // scalar's trailing comment (`l-trail-comments`, production 169).
  inspect(
    each([
      "a: |\n  x\n \t\n", "a: |\n  x\n \t", "a: |\n  x\n \t\n\n# end\n", "a: |\n  x\n \t\n...\n",
      "a: |\n\t\n", "- |\n  x\n \t\n", "a:\n  b: |\n    x\n  \t\n", "a: |\n  x\n \n",
      "a: |\n  x\n# end\n \t\n",
    ]),
    content=(
      #|"a: |\n  x\n \t\n" -> error /a: tabs are not allowed in indentation
      #|"a: |\n  x\n \t" -> error /a: tabs are not allowed in indentation
      #|"a: |\n  x\n \t\n\n# end\n" -> error /a: tabs are not allowed in indentation
      #|"a: |\n  x\n \t\n...\n" -> error /a: tabs are not allowed in indentation
      #|"a: |\n\t\n" -> error /a: tabs are not allowed in indentation
      #|"- |\n  x\n \t\n" -> error /0: tabs are not allowed in indentation
      #|"a:\n  b: |\n    x\n  \t\n" -> error /a/b: tabs are not allowed in indentation
      #|"a: |\n  x\n \n" -> {"a":"x\n"}
      #|"a: |\n  x\n# end\n \t\n" -> {"a":"x\n"}
    ),
  )
  // "Both the "-" indicator and the following spaces are considered to be
  // part of the indentation of the nested collection" (YAML 1.2.2, section
  // 8.2.1), all of that white space, so a tab anywhere in it is a tab in
  // indentation (section 6.1), not only one right before the collection:
  // here a space comes between the tab and the nested mapping or sequence.
  // The messages and pointers are those of the cases above.
  inspect(
    each(["-\t a: 1", "-\t - x", "- -\t a: 1", "stubs:\n-\t  id: a\n    mock: m"]),
    content=(
      #|"-\t a: 1" -> error /0: tabs are not allowed in indentation
      #|"-\t - x" -> error /0: tabs are not allowed in indentation
      #|"- -\t a: 1" -> error /0/0: tabs are not allowed in indentation
      #|"stubs:\n-\t  id: a\n    mock: m" -> error /stubs/0: tabs are not allowed in indentation
    ),
  )
  // A tab in the white space at the start of the first line is rejected
  // too ("a tab in the white space at the start of a line", among the valid
  // YAML that `parse` rejects on purpose). No node has been reached there,
  // so the error names the whole document: "For a syntax error, it names
  // the deepest node the parser reached. It is `""` for the whole
  // document" (`ParseError`), the empty pointer of RFC 6901, section 5.
  inspect(
    each(["\ta: 1", " \ta: 1", "---\n\ta: 1"]),
    content=(
      #|"\ta: 1" -> error : tabs are not allowed in indentation
      #|" \ta: 1" -> error : tabs are not allowed in indentation
      #|"---\n\ta: 1" -> error : tabs are not allowed in indentation
    ),
  )
}

///|
test "unterminated quotes and flow collections give an error at the deepest node reached" {
  inspect(
    each([
      "a: \"abc", "a: 'abc", "a: \"abc\nb: 1", "a: 'abc\n\n", "a: [1, 2", "a: {x: 1",
      "a: [1, 2\nb: 3", "[", "{a: [1, {b: 2}", "a: [1, 2]]", "a: {x: 1}}", "a: \"x\" y",
    ]),
    content=(
      #|"a: \"abc" -> error /a: unterminated double-quoted value
      #|"a: 'abc" -> error /a: unterminated single-quoted value
      #|"a: \"abc\nb: 1" -> error /a: unterminated double-quoted value
      #|"a: 'abc\n\n" -> error /a: unterminated single-quoted value
      #|"a: [1, 2" -> error /a/1: unterminated flow sequence
      #|"a: {x: 1" -> error /a/x: unterminated flow mapping
      #|"a: [1, 2\nb: 3" -> error /a/1: unterminated flow sequence
      #|"[" -> error : unterminated flow sequence
      #|"{a: [1, {b: 2}" -> error /a/1/b: unterminated flow sequence
      #|"a: [1, 2]]" -> error /a/1: unexpected text after the value
      #|"a: {x: 1}}" -> error /a/x: unexpected text after the value
      #|"a: \"x\" y" -> error /a: unexpected text after the value
    ),
  )
  // A flow collection closed by the other bracket, and a key in a flow
  // mapping with no ':' after it. The messages are those #280's acceptance
  // criteria name; the pointer is the deepest node reached, as `parse`
  // documents.
  inspect(
    each(["a: [1}", "a: {x: 1]", "a: {\"x\" 1}"]),
    content=(
      #|"a: [1}" -> error /a/0: expected , or ] in a flow sequence
      #|"a: {x: 1]" -> error /a/x: expected , or } in a flow mapping
      #|"a: {\"x\" 1}" -> error /a/x: expected ':' after a key
    ),
  )
}

///|
test "empty values, empty documents and stray indicators give an error" {
  inspect(
    each([
      "", "# only a comment\n", "---\n", "a:", "a:\nb: 1", "- ", "-\n- b", "{a: }",
      "{a}", "{a: 1,, b: 2}", "[a, , b]", "[a: 1]", ": x", "? a\n: b", "a: @x", "a: `x",
      "a: ,x", "a: %x", "[a]: b", "{a: 1}: b", "a: |2\n  x", "a: |x", "a: \"\\q\"",
      "a: \"\\u12\"", "a: \"\\ud800\"", "a: \"\\udc00\"",
    ]),
    content=(
      #|"" -> error : the document is empty
      #|"# only a comment\n" -> error : the document is empty
      #|"---\n" -> error : the document is empty
      #|"a:" -> error /a: empty value: write null, or "" for an empty string
      #|"a:\nb: 1" -> error /a: empty value: write null, or "" for an empty string
      #|"- " -> error /0: empty value: write null, or "" for an empty string
      #|"-\n- b" -> error /0: empty value: write null, or "" for an empty string
      #|"{a: }" -> error /a: empty value: write null, or "" for an empty string
      #|"{a}" -> error /a: empty value: write null, or "" for an empty string
      #|"{a: 1,, b: 2}" -> error /a: expected a key before ','
      #|"[a, , b]" -> error /1: expected a value before ','
      #|"[a: 1]" -> error /0: a key: value pair in a flow sequence needs braces
      #|": x" -> error : a key must not be empty
      #|"? a\n: b" -> error : explicit keys (?) are not supported
      #|"a: @x" -> error /a: a plain value cannot start with @; quote this value
      #|"a: `x" -> error /a: a plain value cannot start with `; quote this value
      #|"a: ,x" -> error /a: a plain value cannot start with ,; quote this value
      #|"a: %x" -> error /a: a plain value cannot start with %; quote this value
      #|"[a]: b" -> error /0: a key must be a plain or quoted scalar
      #|"{a: 1}: b" -> error /a: a key must be a plain or quoted scalar
      #|"a: |2\n  x" -> error /a: block scalar indentation indicators are not supported
      #|"a: |x" -> error /a: invalid block scalar header
      #|"a: \"\\q\"" -> error /a: invalid escape \q
      #|"a: \"\\u12\"" -> error /a: invalid escape: expected a hexadecimal digit
      #|"a: \"\\ud800\"" -> error /a: invalid escape: a high surrogate must be followed by a low surrogate
      #|"a: \"\\udc00\"" -> error /a: invalid escape: not a Unicode character
    ),
  )
  // A `-` item indicator inside a flow collection: YAML embeds flow nodes
  // in block collections, "but not vice-versa" (YAML 1.2.2, section
  // 8.2.3). The message is the one #280's acceptance criteria name; the
  // pointer is the deepest node reached, the flow sequence's first item, as
  // `parse` documents.
  inspect(
    each(["[- a]"]),
    content=(
      #|"[- a]" -> error /0: a block sequence cannot be inside a flow collection
    ),
  )
}

///|
test "line breaks may be CRLF or CR; a byte order mark may start the text; other control characters are rejected" {
  let cases = [
    ("CRLF", "a: 1\r\nb: |\r\n  x\r\n"),
    ("CR", "a: 1\rb: 2"),
    ("byte order mark", "\u{FEFF}a: 1"),
    ("BEL", "a: \u{7}"),
    ("SOH quoted", "a: \"\u{1}\""),
    ("DEL", "a: \u{7F}"),
    ("U+FFFE", "a: \u{FFFE}"),
    ("NEL", "a: \u{85}"),
    ("LINE SEPARATOR quoted", "a: \"x\u{2028}y\""),
  ]
  inspect(
    cases.map(c => "\{c.0} -> \{yaml(c.1)}").join("\n"),
    content=(
      #|CRLF -> {"a":1,"b":"x\n"}
      #|CR -> {"a":1,"b":2}
      #|byte order mark -> {"a":1}
      #|BEL -> error : U+0007 is a control character; write it as an escape in a double-quoted value
      #|SOH quoted -> error : U+0001 is a control character; write it as an escape in a double-quoted value
      #|DEL -> error : U+007F is a control character; write it as an escape in a double-quoted value
      #|U+FFFE -> error : U+FFFE is a control character; write it as an escape in a double-quoted value
      #|NEL -> error : U+0085 is a line break in YAML 1.1 only; write it as an escape in a double-quoted value
      #|LINE SEPARATOR quoted -> error : U+2028 is a line break in YAML 1.1 only; write it as an escape in a double-quoted value
    ),
  )
  // The first and last character of each range of YAML 1.2.2's character
  // set, and the characters just outside them: "c-printable ::= x09 | x0A
  // | x0D | [x20-x7E] | x85 | [xA0-xD7FF] | [xE000-xFFFD] |
  // [x010000-x10FFFF]" (section 5.1, production 1). "The allowed character
  // range explicitly excludes the C0 control block [x00-x1F] (except for
  // TAB x09, LF x0A, and CR x0D which are allowed), DEL x7F, the C1 control
  // block [x80-x9F] (except for NEL x85 which is allowed), the surrogate
  // block [xD800-xDFFF], xFFFE, and xFFFF" (same section); `parse` rejects
  // control characters ("Rejected, each with a message naming it: ...
  // control characters"). U+2028 and U+2029 are line breaks in YAML 1.1
  // (its `b-char`, section 5.4 of YAML 1.1), and YAML 1.2 reads them, and
  // NEL, as other characters (YAML 1.2.2, section 5.4), so they would mean
  // something else in each version: the subset "keeps a document's meaning
  // the same in every YAML version" (`parse`), and the messages are the
  // ones the cases above give. Each character stands between `x` and `y`
  // in a plain value.
  let edges = [
    0x1F, 0x20, 0x7E, 0x80, 0x84, 0x86, 0x9F, 0xA0, 0x2027, 0x2029, 0x202A, 0xD7FF,
    0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF,
  ]
  inspect(
    edges
    .map(code => {
      let c = code.to_char().unwrap()
      let hex = code.to_string(radix=16).to_upper()
      let label = if hex.length() < 4 {
        "U+" + "0".repeat(4 - hex.length()) + hex
      } else {
        "U+" + hex
      }
      let text = "a: x\{c}y"
      let result = try @yaml.parse(text) catch {
        @yaml.ParseError(pointer~, message~) => "error \{pointer}: \{message}"
      } noraise {
        tree =>
          if tree == Json::object({ "a": Json::string("x\{c}y") }) {
            "read as written"
          } else {
            tree.stringify()
          }
      }
      "\{label} -> \{result}"
    })
    .join("\n"),
    content=(
      #|U+001F -> error : U+001F is a control character; write it as an escape in a double-quoted value
      #|U+0020 -> read as written
      #|U+007E -> read as written
      #|U+0080 -> error : U+0080 is a control character; write it as an escape in a double-quoted value
      #|U+0084 -> error : U+0084 is a control character; write it as an escape in a double-quoted value
      #|U+0086 -> error : U+0086 is a control character; write it as an escape in a double-quoted value
      #|U+009F -> error : U+009F is a control character; write it as an escape in a double-quoted value
      #|U+00A0 -> read as written
      #|U+2027 -> read as written
      #|U+2029 -> error : U+2029 is a line break in YAML 1.1 only; write it as an escape in a double-quoted value
      #|U+202A -> read as written
      #|U+D7FF -> read as written
      #|U+E000 -> read as written
      #|U+FFFD -> read as written
      #|U+FFFF -> error : U+FFFF is a control character; write it as an escape in a double-quoted value
      #|U+10000 -> read as written
      #|U+10FFFF -> read as written
    ),
  )
}

///|
/// The message of the error parsing `text` gives, or "no error".
fn message(text : String) -> String {
  try @yaml.parse(text) catch {
    @yaml.ParseError(message~, ..) => message
  } noraise {
    _ => "no error"
  }
}

///|
test "nesting as deep as the JSON parser allows gives a value; deeper nesting gives an error" {
  // The JSON parser allows 1024 nested collections.
  let flow = (depth : Int32) => "[".repeat(depth) + "]".repeat(depth)
  assert_eq(@yaml.parse(flow(1024)), @json.parse(flow(1024)))
  inspect(message(flow(1025)), content="nesting is deeper than 1024 levels")
  inspect(
    message("[".repeat(100_000)),
    content="nesting is deeper than 1024 levels",
  )
  inspect(
    message("{a: ".repeat(100_000)),
    content="nesting is deeper than 1024 levels",
  )
  // Compact sequences: `- - - x`.
  let compact = (depth : Int32) => "- ".repeat(depth) + "x"
  guard @yaml.parse(compact(1024)) is Array(_) else { fail("not an array") }
  inspect(message(compact(1025)), content="nesting is deeper than 1024 levels")
  inspect(
    message(compact(100_000)),
    content="nesting is deeper than 1024 levels",
  )
  // Mappings nested by indentation.
  let indented = (depth : Int32) => {
    let lines = []
    for i in 0..<depth {
      lines.push(" ".repeat(i) + "a:")
    }
    lines.push(" ".repeat(depth) + "x")
    lines.join("\n")
  }
  guard @yaml.parse(indented(1024)) is Object(_) else { fail("not an object") }
  inspect(message(indented(1025)), content="nesting is deeper than 1024 levels")
}

///|
test "very long scalars and collections give a value, or an error when unterminated" {
  let long = "x".repeat(1_000_000)
  let length = (text : String) => {
    match @yaml.parse(text) {
      String(s) => s.length()
      Object(m) =>
        match m.get("a") {
          Some(String(s)) => s.length()
          Some(Array(items)) => items.length()
          _ => -1
        }
      _ => -1
    }
  }
  inspect(length(long), content="1000000")
  inspect(length("a: \{long}"), content="1000000")
  inspect(length("a: \"\{long}\""), content="1000000")
  inspect(length("a: '\{"''".repeat(500_000)}'"), content="500000")
  inspect(length("a: |\n" + "  line\n".repeat(100_000)), content="500000")
  inspect(length("a: >\n" + "  word\n".repeat(100_000)), content="500000")
  inspect(length("a: x\{" ".repeat(1_000_000)}y"), content="1000002")
  inspect(length("a: x\n" + "  y\n".repeat(100_000)), content="200001")
  inspect(length("a: [" + "1, ".repeat(100_000) + "]"), content="100000")
  inspect(length("a:\n" + "- 1\n".repeat(100_000)), content="100000")
  inspect(@yaml.parse("\{long}: 1").stringify().length(), content="1000006")
  inspect(message("a: \"\{long}"), content="unterminated double-quoted value")
  inspect(message("a: '\{long}"), content="unterminated single-quoted value")
  inspect(message("a: [\{long}"), content="unterminated flow sequence")
  inspect(
    message("a: [" + "1, ".repeat(100_000)),
    content="unterminated flow sequence",
  )
}

///|
test "every other plain scalar is a string" {
  inspect(
    yaml(
      (
        #|- GET
        #|- /users/1?x=y
        #|- http://a.example:8080/x
        #|- a#b
        #|- a:b
        #|- truex
        #|- nullable
        #|- 1.2.3-rc
        #|- 1e
        #|- -a
        #|- .
        #|- 0x
        #|- 12:30 pm
        #|- v1
      ),
    ),
    content=(
      #|["GET","/users/1?x=y","http://a.example:8080/x","a#b","a:b","truex","nullable","1.2.3-rc","1e","-a",".","0x","12:30 pm","v1"]
    ),
  )
}
