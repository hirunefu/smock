// Tests of the helpers that read the pinned Unicode data (`uppercase`,
// `lowercase` and `trim`), through the template package's public
// interface. They run on native and on wasm-gc, and give the same output on
// both.

///|
/// A request whose query and body hold text with White_Space beyond ASCII,
/// text without case, and the other kinds of JSON values.
let spaced : @template.Input = {
  meth: "GET",
  path: "/",
  query: [
    ("n", "42"),
    ("name", "\u{3000}Ann "),
    ("lines", "\t\n Ann Lee \r\n"),
    ("nbsp", "\u{A0}Ann\u{A0}"),
    (
      "others", "\u{85}\u{1680}\u{2000}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}x\u{B}\u{C}",
    ),
    ("zero", "\u{200B}x\u{FEFF}"),
    ("mongolian", "\u{180E}x"),
    ("blank", " \u{3000}\t"),
    ("emoji", " 👍🏽 "),
  ],
  headers: [],
  body: @utf8.encode(
    (
      #|{ "code": "straße-ç", "cjk": "日本語", "emoji": "👍🏽", "list": ["a"],
      #|  "none": null, "object": { "a": 1 }, "big": 12345678901234567890 }
    ),
  ),
}

///|
test "uppercase and lowercase map each code point to its simple case, one to one, so ß, which has no upper case of one code point, stays" {
  inspect(
    [
      rendered(
        "${uppercase(body.code)} ${lowercase('STRASSE-Ç')} ${uppercase('ß')}",
        input=spaced,
      ),
      rendered("${uppercase('ŉ ﬀ ǰ')} ${lowercase('İ')}", input=spaced),
    ].join("\n"),
    content=(
      #|STRAßE-Ç strasse-ç ß
      #|ŉ ﬀ ǰ i
    ),
  )
}

///|
test "uppercase and lowercase map letters beyond Latin, in the BMP and beyond it, and leave characters without case as they are" {
  inspect(
    [
      rendered(
        "${uppercase('αβγ ς')} ${lowercase('ΟΔΥΣΣΕΥΣ')}",
        input=spaced,
      ),
      rendered(
        "${uppercase('привет')} ${lowercase('МОСКВА')}",
        input=spaced,
      ),
      rendered(
        "${uppercase('ａｂｃ')} ${lowercase('ＡＢＣ')}",
        input=spaced,
      ),
      rendered(
        "${uppercase('ĀāĂă')} ${lowercase('ĀāĂă')} ${uppercase('ѠѡѢѣ')} ${lowercase('ѠѡѢѣ')}",
        input=spaced,
      ),
      rendered("${uppercase('𐐨')} ${lowercase('𐐀')}", input=spaced),
      rendered(
        "${uppercase('ǅ')} ${lowercase('ǅ')} ${lowercase('K')} ${uppercase('ƛ')}",
        input=spaced,
      ),
      rendered(
        "${uppercase(body.cjk)} ${lowercase(body.emoji)} ${uppercase('123 -_ ½')}",
        input=spaced,
      ),
    ].join("\n"),
    content=(
      #|ΑΒΓ Σ οδυσσευσ
      #|ПРИВЕТ москва
      #|ＡＢＣ ａｂｃ
      #|ĀĀĂĂ āāăă ѠѠѢѢ ѡѡѣѣ
      #|𐐀 𐐨
      #|Ǆ ǆ k Ƛ
      #|日本語 👍🏽 123 -_ ½
    ),
  )
}

///|
test "uppercase and lowercase use no locale: i is I and ı is I, as everywhere" {
  inspect(
    rendered(
      "${uppercase('i')} ${uppercase('ı')} ${lowercase('I')} ${lowercase('İ')}",
      input=spaced,
    ),
    content=(
      #|I I i i
    ),
  )
}

///|
test "trim removes White_Space at both ends, beyond ASCII too, and keeps what is between" {
  inspect(
    [
      rendered(
        "[${trim(query.name)}] [${trim(query.lines)}] [${trim(query.nbsp)}] [${trim(query.others)}]",
        input=spaced,
      ),
      rendered(
        "[${trim(query.blank)}] [${trim('')}] [${trim(query.emoji)}] [${trim(' a b ')}]",
        input=spaced,
      ),
    ].join("\n"),
    content=(
      #|[Ann] [Ann Lee] [Ann] [x]
      #|[] [] [👍🏽] [a b]
    ),
  )
}

///|
test "trim keeps what only looks like space: ZERO WIDTH SPACE, ZERO WIDTH NO-BREAK SPACE and MONGOLIAN VOWEL SEPARATOR are not White_Space" {
  inspect(
    rendered(
      "${len(trim(query.zero))} ${len(trim(query.mongolian))}",
      input=spaced,
    ),
    content=(
      #|3 2
    ),
  )
}

///|
test "uppercase, lowercase and trim take a number or a boolean as its text, and refuse null, an object or an array" {
  inspect(
    [
      rendered(
        "${uppercase(true)} ${lowercase(1.50)} ${uppercase(query.n)} ${lowercase(body.big)} ${trim(false)} ${trim(2.0)}",
        input=spaced,
      ),
      rendered("${uppercase(query.missing) ?? 'none'}", input=spaced),
      rendered_json(
        "{ \"code\": \"${uppercase(body.code)}\", \"name\": \"${trim(query.name)}\" }",
        input=spaced,
      ),
      rendered("${uppercase(body.none)}", input=spaced),
      rendered("${lowercase(body.list)}", input=spaced),
      rendered("${trim(body.object)}", input=spaced),
      rendered("${uppercase(null)}", input=spaced),
      rendered("${lowercase(body.x ?? null)}", input=spaced),
      rendered("${trim(null)}", input=spaced),
      rendered("${trim()}", input=spaced),
      rendered("${uppercase('a', 'b')}", input=spaced),
    ].join("\n"),
    content=(
      #|TRUE 1.5 42 12345678901234567890 false 2
      #|none
      #|{"code":"STRAßE-Ç","name":"Ann"}
      #|error at /response/body: uppercase(): argument 1 must be a string, a number or a boolean, not null
      #|error at /response/body: lowercase(): argument 1 must be a string, a number or a boolean, not an array
      #|error at /response/body: trim(): argument 1 must be a string, a number or a boolean, not an object
      #|problem at /response/body: template: column 13: uppercase(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 13: lowercase(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 8: trim(): argument 1 must be a string, a number or a boolean, not null
      #|problem at /response/body: template: column 3: trim() takes 1 argument, not 0
      #|problem at /response/body: template: column 3: uppercase() takes 1 argument, not 2
    ),
  )
}

///|
/// A request whose body holds the text `text` as `s`.
fn holding(text : String) -> @template.Input {
  { ..spaced, body: @utf8.encode("{\"s\":\"\{text}\"}"), }
}

///|
test "a case mapping that takes more bytes of UTF-8 than its text, and a trimmed text, are bounded to 1 MiB, measured before they are built" {
  // ɐ takes two bytes and Ɐ, its upper case, three: 400,000 of them take
  // 800,000 bytes, and 1,200,000 in upper case.
  let small = holding("ɐ".repeat(400000))
  let large = holding("Ɐ".repeat(400000))
  // 1 MiB of text, and one byte more, between spaces and a tab, which
  // the JSON of the body writes as `\t`.
  let fits = holding(" ".repeat(300000) + "a".repeat(1048576) + "\\t")
  let beyond = holding(" ".repeat(300000) + "a".repeat(1048577) + "\\t")
  inspect(
    [
      rendered("${len(lowercase(body.s))}", input=small),
      rendered("${len(uppercase(body.s))}", input=small),
      rendered("${len(lowercase(body.s))}", input=large),
      rendered("${len(uppercase(body.s))}", input=large),
      rendered("${len(trim(body.s))}", input=fits),
      rendered("${len(trim(body.s))}", input=beyond),
      rendered("${len(trim(body.s))}", input=large),
    ].join("\n"),
    content=(
      #|400000
      #|error at /response/body: uppercase(): the result takes more than 1 MiB
      #|400000
      #|error at /response/body: uppercase(): the result takes more than 1 MiB
      #|1048576
      #|error at /response/body: trim(): the result takes more than 1 MiB
      #|error at /response/body: trim(): the result takes more than 1 MiB
    ),
  )
}
