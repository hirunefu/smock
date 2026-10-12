///|
/// `n` copies of `s`.
fn repeat(s : String, n : Int) -> String {
  let b = StringBuilder()
  for _ in 0..<n {
    b.write_string(s)
  }
  b.to_string()
}

///|
fn ascii(s : String) -> BytesView {
  @utf8.encode(s)[:]
}

///|
test "repetition counts up to 1000 are allowed, as in RE2" {
  let re = @re2.compile("a{1000}")
  assert_true(re.full_match(ascii(repeat("a", 1000))))
  assert_false(re.full_match(ascii(repeat("a", 999))))
  assert_true(
    @re2.compile("a{0,1000}b").full_match(ascii(repeat("a", 1000) + "b")),
  )
  inspect(
    errors(["a{1001}", "a{0,1001}", "a{1001,}", "ab{999999999}"]),
    content=(
      #|a{1001} => position 1: invalid repetition size {1001}
      #|a{0,1001} => position 1: invalid repetition size {0,1001}
      #|a{1001,} => position 1: invalid repetition size {1001,}
      #|ab{999999999} => position 2: invalid repetition size {999999999}
    ),
  )
}

///|
test "nested repetition counts may multiply to at most 1000, as in RE2" {
  for
    pattern in [
      "(a{2}){500}", "((a{10}){10}){10}", "(a{2,}){500}", "(a{0,2}){500}", "(a*){1000}",
      "(?:a{1000}){1}", "(?:a{1000}){0}", "a{1000}b{1000}",
    ] {
    @re2.compile(pattern) |> ignore
  }
  inspect(
    errors([
      "(a{2}){501}", "((a{10}){10}){11}", "(a{0,2}){501}", "x(?:a{2,}b{3}){334}",
    ]),
    content=(
      #|(a{2}){501} => position 6: nested repetition counts multiply to more than 1000 at {501}
      #|((a{10}){10}){11} => position 13: nested repetition counts multiply to more than 1000 at {11}
      #|(a{0,2}){501} => position 8: nested repetition counts multiply to more than 1000 at {501}
      #|x(?:a{2,}b{3}){334} => position 14: nested repetition counts multiply to more than 1000 at {334}
    ),
  )
}

///|
test "a pattern whose compiled program is too large is a compile error" {
  // Each x{1000} compiles to a thousand instructions. The limit is 100 000.
  let fits = repeat("x{1000}", 50)
  assert_true(@re2.compile(fits).full_match(ascii(repeat("x", 50000))))
  for
    pattern in [
      repeat("x{1000}", 101),
      repeat("(?:abcdefghij|klmnopqrst){100}", 100),
    ] {
    inspect(
      error_of(pattern),
      content="position 0: pattern too large: it compiles to more than 100000 instructions",
    )
  }
}

///|
test "groups may nest 100 deep" {
  let deep = repeat("(", 100) + "a" + repeat(")", 100)
  assert_true(@re2.compile(deep).full_match(ascii("a")))
  let deep_repeats = repeat("(?:", 100) + "a" + repeat(")*", 100)
  assert_true(@re2.compile(deep_repeats).full_match(ascii("aaa")))
  let deep_alternations = repeat("(?:b|", 100) + "a" + repeat(")+", 100)
  assert_true(@re2.compile(deep_alternations).full_match(ascii("abba")))
  inspect(
    error_of(repeat("(", 101) + "a" + repeat(")", 101)),
    content="position 100: groups nest more than 100 deep",
  )
  inspect(
    error_of("x" + repeat("(?i:", 101) + "a" + repeat(")", 101)),
    content="position 401: groups nest more than 100 deep",
  )
}
