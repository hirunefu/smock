// Matching never backtracks, so its work grows linearly with the input.
// These tests count matcher steps instead of timing, so they are exact and
// cannot be flaky: for a linear matcher, doubling the input at most doubles
// the steps (plus a little for the ends of the input).

///|
/// Patterns that take exponential or high-polynomial time in a backtracking
/// matcher on `aaa...a!`: nested quantifiers and overlapping alternation.
let pathological : Array[String] = [
  "(a+)+$", "(a*)*b", "((a*)*)*b", "(a|a)*b", "(a|aa)+$", "(?:a|ab|b)*c", "(\\w|\\d)+!!",
  "(.*)*x", "(.*a){10}b", "(a+|b+|ab)+$", "(x+x+)+y", "(?:a?){30}a{30}b", "(a{1,10}){1,10}b",
  "^(a+)+$", "(?i)(A|a)*b", "(?s)(.|\n)*z",
]

///|
/// `a` repeated `n` times, then `!`: no pattern above matches it.
fn input_of(n : Int32) -> Bytes {
  @utf8.encode(repeat("a", n) + "!")
}

///|
test "search steps grow linearly on pathological patterns" {
  for pattern in pathological {
    let re = @re2.compile(pattern)
    let mut previous = re.search_steps(input_of(1000)[:])
    for n in [2000, 4000, 8000] {
      let steps = re.search_steps(input_of(n)[:])
      if steps.to_double() > 2.1 * previous.to_double() {
        fail(
          "\{pattern}: \{steps} steps for \{n} bytes, \{previous} for half that",
        )
      }
      previous = steps
    }
  }
}

///|
test "full_match steps grow linearly on pathological patterns" {
  for pattern in pathological {
    let re = @re2.compile(pattern)
    let mut previous = re.full_match_steps(input_of(1000)[:])
    for n in [2000, 4000, 8000] {
      let steps = re.full_match_steps(input_of(n)[:])
      if steps.to_double() > 2.1 * previous.to_double() {
        fail(
          "\{pattern}: \{steps} steps for \{n} bytes, \{previous} for half that",
        )
      }
      previous = steps
    }
  }
}

///|
test "a pathological pattern on a long input takes a bounded number of steps per byte" {
  // A backtracking matcher needs about 2^n steps for (a+)+$ on n a's and a
  // !, and about n^10 for (.*a){10}b.
  let input = input_of(100000)
  debug_inspect(@re2.compile("(a+)+$").search(input[:]), content="None")
  let steps = @re2.compile("(a+)+$").search_steps(input[:])
  assert_true(steps < 100 * input.length(), msg="\{steps} steps")
  let steps = @re2.compile("(.*a){10}b").search_steps(input[:])
  assert_true(steps < 1000 * input.length(), msg="\{steps} steps")
}

///|
test "steps count the work of the match they describe" {
  let re = @re2.compile("a+b")
  // Finding a match early stops the search.
  assert_true(
    re.search_steps(b"ab"[:]) <
    re.search_steps(@utf8.encode(repeat("x", 100) + "ab")[:]),
  )
  // full_match gives up as soon as no thread is left.
  assert_true(
    re.full_match_steps(@utf8.encode("x" + repeat("a", 1000))[:]) < 10,
  )
}
