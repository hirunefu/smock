///|
test "search returns the byte span of the leftmost match" {
  let re = @re2.compile("abc")
  debug_inspect(
    re.search(b"xxabcxabc"[:]),
    content="Some({ start: 2, end: 5 })",
  )
  debug_inspect(re.search(b"xxabx"[:]), content="None")
}

///|
test "full_match is true only when the pattern matches the entire input" {
  let re = @re2.compile("abc")
  assert_true(re.full_match(b"abc"[:]))
  assert_false(re.full_match(b"abcd"[:]))
  assert_false(re.full_match(b"xabc"[:]))
  assert_false(re.full_match(b""[:]))
}

///|
test "a compile error position counts characters, not bytes" {
  // é is two bytes in UTF-8 and 😀 four (two UTF-16 code units).
  inspect(error_of("é😀a)"), content="position 3: unexpected )")
  inspect(error_of("é😀[a"), content="position 2: missing closing ]")
}

///|
test "an escaped metacharacter matches itself" {
  let re = @re2.compile("a\\.b\\*\\\\\\(\\)\\[\\]\\{\\}\\|\\^\\$\\+\\?\\-\\/")
  assert_true(re.full_match(b"a.b*\\()[]{}|^$+?-/"[:]))
  assert_false(re.full_match(b"axb*\\()[]{}|^$+?-/"[:]))
}

///|
test "a compile error carries its position in the pattern and a message" {
  let error = try @re2.compile("ab\\") catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  guard error is Some(CompileError(position~, message~)) else {
    fail("expected a compile error")
  }
  inspect(position, content="2")
  inspect(message, content="trailing backslash at end of pattern")
  inspect(
    error.unwrap().to_string(),
    content="position 2: trailing backslash at end of pattern",
  )
}
