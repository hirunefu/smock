// `full_match` against the Pike VM, which decides it by following every
// way through the program: for random patterns over every construct of R1,
// assertions and flags included, and random inputs, ill-formed UTF-8
// included, both must agree.

///|
/// Pieces of patterns: characters of one and two bytes, a `\n`, classes,
/// Perl classes and every assertion.
let atoms : Array[String] = [
  "a", "b", "_", " ", "é", "\n", "1", ".", "[ab]", "[^a]", "[a-zé]", "[^\n]", "\\w",
  "\\W", "\\d", "\\s", "^", "$", "\\A", "\\z", "\\b", "\\B",
]

///|
/// Characters of the inputs, and bytes that are not well-formed UTF-8: a
/// lone continuation byte, a truncated two-byte sequence and a byte that
/// never starts one.
let input_pieces : Array[Bytes] = [
  b"a", b"b", b"A", b"_", b" ", b"1", b"\n", b"\xc3\xa9", b"\xe2\x82\xac", b"\x80",
  b"\xc3", b"\xff",
]

///|
/// A random pattern of nested concatenations, alternations, groups and
/// repetitions, `depth` levels deep at most.
fn random_pattern(rand : @random.Rand, depth : Int) -> String {
  let pick = (items : Array[String]) => items[rand.int(limit=items.length())]
  if depth == 0 || rand.int(limit=3) == 0 {
    return pick(atoms)
  }
  match rand.int(limit=4) {
    0 => {
      let out = StringBuilder()
      for _ in 0..<(1 + rand.int(limit=4)) {
        out.write_string(random_pattern(rand, depth - 1))
      }
      out.to_string()
    }
    1 => random_pattern(rand, depth - 1) + "|" + random_pattern(rand, depth - 1)
    2 => {
      let open = pick(["(", "(?:", "(?i:", "(?s:", "(?m:"])
      open + random_pattern(rand, depth - 1) + ")"
    }
    _ => {
      let sub = random_pattern(rand, depth - 1)
      "(?:" +
      sub +
      ")" +
      pick(["*", "+", "?", "{0,2}", "{1,3}", "{2}", "*?", "+?"])
    }
  }
}

///|
fn random_input(rand : @random.Rand) -> Bytes {
  let out = @buffer.Buffer()
  for _ in 0..<rand.int(limit=9) {
    let piece = if rand.int(limit=12) == 0 {
      input_pieces[input_pieces.length() - 1 - rand.int(limit=3)]
    } else {
      input_pieces[rand.int(limit=input_pieces.length() - 3)]
    }
    out.write_bytes(piece)
  }
  out.to_bytes()
}

///|
test "full_match agrees with the Pike VM on random patterns and inputs" {
  let rand = @random.Rand::chacha8(seed=b"smock re2 full_match vs pike vm.")
  let differ = []
  let mut compared = 0
  let mut matched = 0
  let mut patterns = 0
  let mut by_dfa = 0
  for _ in 0..<3000 {
    let flags = ["", "(?m)", "(?s)", "(?i)", "(?ms)"][rand.int(limit=5)]
    let pattern = flags + random_pattern(rand, 3)
    let re = compile(pattern) catch { _ => continue }
    for _ in 0..<40 {
      let input = random_input(rand)
      let expected = run(re.insts, input[:], Full).0 is Some(_)
      if re.full_match(input[:]) != expected && differ.length() < 5 {
        differ.push((pattern, input))
      }
      compared += 1
      if expected {
        matched += 1
      }
    }
    patterns += 1
    if re.dfa is Built(_) {
      by_dfa += 1
    }
  }
  debug_inspect(differ, content="[]")
  // Enough of the inputs match for the comparison to mean something, and
  // the DFA, not the Pike VM it falls back to, decided them.
  assert_true(matched * 20 > compared)
  assert_eq(by_dfa, patterns)
}

///|
test "a regex whose DFA would outgrow its budget drops it and gets the same results from the Pike VM" {
  // Telling whether the 15th character from the end is an `a` takes a
  // state for each of the 2^15 ways the last 15 characters can be.
  let re = compile("(?:a|b)*a(?:a|b){14}")
  let rand = @random.Rand::chacha8(seed=b"smock re2 dfa over its budget!!!")
  let differ = []
  for _ in 0..<300 {
    let input = @buffer.Buffer()
    for _ in 0..<(15 + rand.int(limit=40)) {
      input.write_byte(if rand.int(limit=2) == 0 { b'a' } else { b'b' })
    }
    let input = input.to_bytes()
    let expected = run(re.insts, input[:], Full).0 is Some(_)
    if re.full_match(input[:]) != expected {
      differ.push(input)
    }
  }
  debug_inspect(differ, content="[]")
  assert_true(re.dfa is TooLarge)
}
