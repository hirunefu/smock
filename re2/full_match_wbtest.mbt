// `full_match` against the Pike VM, which decides it by following every
// way through the program: for random patterns over every construct of
// smock's RE2 subset, assertions and flags included, random inputs,
// ill-formed UTF-8 included, and inputs spelt from the pattern, both must
// agree. The first test is a property, with core's QuickCheck: it reports
// its input classes, and a failure shrinks to its smallest pattern and
// inputs (#295).

///|
/// The seed of the property that `full_match` agrees with the Pike VM. The
/// tests run with it on every push, in mutation runs and in kill
/// confirmations, so a failure reproduces. Each week,
/// `scripts/random-seeds.py` writes a random seed here in a working copy and
/// prints it (CONTRIBUTING.md, "Seeds").
const FULL_MATCH_SEED : UInt64 = 17552659360335093416

///|
/// Pieces of patterns: characters of one and two bytes, a `\n`, classes,
/// Perl classes and every assertion.
let atoms : Array[String] = [
  "a", "b", "_", " ", "é", "\n", "1", ".", "[ab]", "[^a]", "[a-zé]", "[^\n]", "\\w",
  "\\W", "\\d", "\\s", "^", "$", "\\A", "\\z", "\\b", "\\B",
]

///|
/// The assertions among `atoms`.
let assertions : Array[String] = ["^", "$", "\\A", "\\z", "\\b", "\\B"]

///|
/// The classes among `atoms`: `.`, bracketed classes and Perl classes.
let classes : Array[String] = [
  ".", "[ab]", "[^a]", "[a-zé]", "[^\n]", "\\w", "\\W", "\\d", "\\s",
]

///|
/// How a group of a pattern opens: capturing, not capturing, or with a flag.
let group_openers : Array[String] = ["(", "(?:", "(?i:", "(?s:", "(?m:"]

///|
/// The repetitions of a pattern, greedy and lazy, with and without counts.
let repetitions : Array[String] = [
  "*", "+", "?", "{0,2}", "{1,3}", "{2}", "*?", "+?",
]

///|
/// The flags a whole pattern may start with.
let flag_sets : Array[String] = ["", "(?m)", "(?s)", "(?i)", "(?ms)"]

///|
/// Characters of the inputs, and bytes that are not well-formed UTF-8: a
/// lone continuation byte, a truncated two-byte sequence and a byte that
/// never starts one.
let input_pieces : Array[Bytes] = [
  b"a", b"b", b"A", b"_", b" ", b"1", b"\n", b"\xc3\xa9", b"\xe2\x82\xac", b"\x80",
  b"\xc3", b"\xff",
]

///|
/// The number of random inputs of each case, as the old random test had
/// for each pattern.
const RANDOM_INPUTS : Int32 = 40

///|
/// The number of inputs of each case spelt from its pattern, after the
/// random ones. Most random inputs miss the pattern early; these reach
/// further into it, and match or nearly match.
const SPELT_INPUTS : Int32 = 20

///|
/// The most pieces an input spelt from a pattern has: past it, the spelling
/// stops, and the input is cut short.
const MAX_SPELT_PIECES : Int32 = 16

///|
/// A pattern as the tree it was generated from, so that a failing pattern
/// shrinks to a smaller one. Its text is its parts written one after
/// another, so an alternation inside a concatenation reads as a wider
/// alternation, as in the text the old random test wrote.
#derive(Debug)
priv enum Pattern {
  /// One of `atoms`.
  Atom(String)
  /// The patterns one after another.
  Sequence(Array[Pattern])
  /// One pattern, `|`, the other.
  Either(Pattern, Pattern)
  /// The pattern in a group that opens with one of `group_openers`.
  Grouped(String, Pattern)
  /// The pattern in a group without capture, followed by one of
  /// `repetitions`.
  Repeated(Pattern, String)
}

///|
/// One case of the property: a pattern, after its flags, and the inputs
/// matched with one regex compiled from it, in order. Each input is a list
/// of `input_pieces`.
#derive(Debug)
priv struct Case {
  flags : String
  pattern : Pattern
  inputs : Array[Array[Bytes]]
}

///|
/// The index of a random one of `n` choices.
fn below(state : @quickcheck.RandomState, n : Int32) -> Int32 {
  state.next_uint(limit=n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// A random pattern of nested concatenations, alternations, groups and
/// repetitions, `depth` levels deep at most.
fn Pattern::random(state : @quickcheck.RandomState, depth : Int32) -> Pattern {
  let pick = (items : Array[String]) => items[below(state, items.length())]
  if depth == 0 || below(state, 3) == 0 {
    return Atom(pick(atoms))
  }
  match below(state, 4) {
    0 => {
      let parts = []
      for _ in 0..<(1 + below(state, 4)) {
        parts.push(Pattern::random(state, depth - 1))
      }
      Sequence(parts)
    }
    1 => {
      let left = Pattern::random(state, depth - 1)
      Either(left, Pattern::random(state, depth - 1))
    }
    2 => {
      let open = pick(group_openers)
      Grouped(open, Pattern::random(state, depth - 1))
    }
    _ => {
      let inner = Pattern::random(state, depth - 1)
      Repeated(inner, pick(repetitions))
    }
  }
}

///|
/// A random input of up to eight pieces; one piece in twelve, on average,
/// is ill-formed UTF-8.
fn random_input(state : @quickcheck.RandomState) -> Array[Bytes] {
  let well_formed = input_pieces.length() - 3
  let pieces = []
  for _ in 0..<below(state, 9) {
    pieces.push(
      if below(state, 12) == 0 {
        input_pieces[well_formed + below(state, 3)]
      } else {
        input_pieces[below(state, well_formed)]
      },
    )
  }
  pieces
}

///|
/// The well-formed input pieces that an atom matches without flags, by
/// RE2's syntax: `.` matches any character but `\n`, `\w` is `[0-9A-Za-z_]`,
/// `\d` is `[0-9]` and `\s` is `[\t\n\f\r ]`. An assertion matches none.
fn matching_pieces(atom : String) -> Array[Bytes] {
  let any_but_newline = [
    b"a", b"b", b"A", b"_", b" ", b"1", b"\xc3\xa9", b"\xe2\x82\xac",
  ]
  match atom {
    "a" => [b"a"]
    "b" => [b"b"]
    "_" => [b"_"]
    " " => [b" "]
    "é" => [b"\xc3\xa9"]
    "\n" => [b"\n"]
    "1" => [b"1"]
    "." | "[^\n]" => any_but_newline
    "[ab]" => [b"a", b"b"]
    "[^a]" =>
      [b"b", b"A", b"_", b" ", b"1", b"\n", b"\xc3\xa9", b"\xe2\x82\xac"]
    "[a-zé]" => [b"a", b"b", b"\xc3\xa9"]
    "\\w" => [b"a", b"b", b"A", b"_", b"1"]
    "\\W" => [b" ", b"\n", b"\xc3\xa9", b"\xe2\x82\xac"]
    "\\d" => [b"1"]
    "\\s" => [b" ", b"\n"]
    _ => []
  }
}

///|
/// The least and the most times a repetition repeats in a spelt input:
/// up to 3 where it has no bound.
fn repeat_range(repetition : String) -> (Int32, Int32) {
  match repetition {
    "+" | "+?" | "{1,3}" => (1, 3)
    "?" => (0, 1)
    "{0,2}" => (0, 2)
    "{2}" => (2, 2)
    _ => (0, 3)
  }
}

///|
/// Spells a random input from the pattern into `out`: a piece that each
/// atom matches without flags, one side of each alternation, and each
/// repetition repeated as often as it allows. Assertions and flags are not
/// heeded, so the input may not match.
fn Pattern::spell(
  self : Pattern,
  state : @quickcheck.RandomState,
  out : Array[Bytes],
) -> Unit {
  match self {
    Atom(atom) => {
      let pieces = matching_pieces(atom)
      if !pieces.is_empty() && out.length() < MAX_SPELT_PIECES {
        out.push(pieces[below(state, pieces.length())])
      }
    }
    Sequence(parts) =>
      for part in parts {
        part.spell(state, out)
      }
    Either(left, right) =>
      if below(state, 2) == 0 {
        left.spell(state, out)
      } else {
        right.spell(state, out)
      }
    Grouped(_, inner) => inner.spell(state, out)
    Repeated(inner, repetition) => {
      let (least, most) = repeat_range(repetition)
      for _ in 0..<(least + below(state, most - least + 1)) {
        inner.spell(state, out)
      }
    }
  }
}

///|
/// The pattern's text.
fn Pattern::write(self : Pattern, out : StringBuilder) -> Unit {
  match self {
    Atom(atom) => out.write_string(atom)
    Sequence(parts) =>
      for part in parts {
        part.write(out)
      }
    Either(left, right) => {
      left.write(out)
      out.write_char('|')
      right.write(out)
    }
    Grouped(open, inner) => {
      out.write_string(open)
      inner.write(out)
      out.write_char(')')
    }
    Repeated(inner, repetition) => {
      out.write_string("(?:")
      inner.write(out)
      out.write_char(')')
      out.write_string(repetition)
    }
  }
}

///|
/// Whether some atom of the pattern is one of `items`.
fn Pattern::has_atom(self : Pattern, items : Array[String]) -> Bool {
  match self {
    Atom(atom) => items.contains(atom)
    Sequence(parts) => parts.iter().any(part => part.has_atom(items))
    Either(left, right) => left.has_atom(items) || right.has_atom(items)
    Grouped(_, inner) | Repeated(inner, _) => inner.has_atom(items)
  }
}

///|
/// Whether the pattern repeats some part of it.
fn Pattern::repeats(self : Pattern) -> Bool {
  match self {
    Atom(_) => false
    Sequence(parts) => parts.iter().any(Pattern::repeats)
    Either(left, right) => left.repeats() || right.repeats()
    Grouped(_, inner) => inner.repeats()
    Repeated(_, _) => true
  }
}

///|
/// Whether the pattern has an alternation.
fn Pattern::alternates(self : Pattern) -> Bool {
  match self {
    Atom(_) => false
    Sequence(parts) => parts.iter().any(Pattern::alternates)
    Either(_, _) => true
    Grouped(_, inner) | Repeated(inner, _) => inner.alternates()
  }
}

///|
/// Whether some group of the pattern sets a flag.
fn Pattern::sets_flags(self : Pattern) -> Bool {
  match self {
    Atom(_) => false
    Sequence(parts) => parts.iter().any(Pattern::sets_flags)
    Either(left, right) => left.sets_flags() || right.sets_flags()
    Grouped(open, inner) =>
      ["(?i:", "(?s:", "(?m:"].contains(open) || inner.sets_flags()
    Repeated(inner, _) => inner.sets_flags()
  }
}

///|
/// Smaller patterns: the pattern's parts in its place, its labels made the
/// simplest, and each part made smaller in place. Each has fewer nodes, or
/// as many with more of the simplest labels, so shrinking ends.
fn Pattern::smaller(self : Pattern) -> Array[Pattern] {
  match self {
    Atom(atom) => if atom == "a" { [] } else { [Atom("a")] }
    Sequence(parts) => {
      let out = parts.copy()
      if parts.length() > 1 {
        for i in 0..<parts.length() {
          let rest = parts.copy()
          rest.remove(i) |> ignore
          out.push(Sequence(rest))
        }
      }
      for i, part in parts {
        for smaller in part.smaller() {
          let changed = parts.copy()
          changed[i] = smaller
          out.push(Sequence(changed))
        }
      }
      out
    }
    Either(left, right) =>
      [
        left,
        right,
        ..left.smaller().map(left => Either(left, right)),
        ..right.smaller().map(right => Either(left, right)),
      ]
    Grouped(open, inner) =>
      [
        inner,
        ..if open == "(?:" {
          []
        } else {
          [Grouped("(?:", inner)]
        },
        ..inner.smaller().map(inner => Grouped(open, inner)),
      ]
    Repeated(inner, repetition) =>
      [
        inner,
        ..if repetition == "*" {
          []
        } else {
          [Repeated(inner, "*")]
        },
        ..inner.smaller().map(inner => Repeated(inner, repetition)),
      ]
  }
}

///|
/// Smaller inputs: each without one of its pieces, and each piece that is
/// not `a` made `a`.
fn smaller_inputs(input : Array[Bytes]) -> Array[Array[Bytes]] {
  let out = []
  for i in 0..<input.length() {
    let rest = input.copy()
    rest.remove(i) |> ignore
    out.push(rest)
  }
  for i, piece in input {
    if piece != b"a" {
      let changed = input.copy()
      changed[i] = b"a"
      out.push(changed)
    }
  }
  out
}

///|
/// The pattern's text, after its flags.
fn Case::text(self : Case) -> String {
  let out = StringBuilder()
  out.write_string(self.flags)
  self.pattern.write(out)
  out.to_string()
}

///|
/// An input's bytes.
fn joined(input : Array[Bytes]) -> Bytes {
  let out = @buffer.Buffer()
  for piece in input {
    out.write_bytes(piece)
  }
  out.to_bytes()
}

///|
/// The size is the patterns' depth, up to the three levels of the old
/// random test, so the first cases are the smallest.
impl @quickcheck.Arbitrary for Case with fn arbitrary(size, state) {
  let flags = flag_sets[below(state, flag_sets.length())]
  let pattern = Pattern::random(state, if size < 3 { size } else { 3 })
  let inputs = []
  for _ in 0..<RANDOM_INPUTS {
    inputs.push(random_input(state))
  }
  for _ in 0..<SPELT_INPUTS {
    let input = []
    pattern.spell(state, input)
    inputs.push(input)
  }
  { flags, pattern, inputs, }
}

///|
/// Fewer inputs first (each one alone, then all but one), then no flags, a
/// smaller pattern, and smaller inputs.
impl @quickcheck.Shrink for Case with fn shrink(self) {
  let out : Array[Case] = []
  let inputs = self.inputs
  if inputs.length() > 1 {
    for input in inputs {
      out.push({ ..self, inputs: [input], })
    }
    for i in 0..<inputs.length() {
      let rest = inputs.copy()
      rest.remove(i) |> ignore
      out.push({ ..self, inputs: rest, })
    }
  }
  if self.flags != "" {
    out.push({ ..self, flags: "", })
  }
  for pattern in self.pattern.smaller() {
    out.push({ ..self, pattern, })
  }
  for i, input in inputs {
    for smaller in smaller_inputs(input) {
      let changed = inputs.copy()
      changed[i] = smaller
      out.push({ ..self, inputs: changed, })
    }
  }
  out.iter()
}

///|
/// What a regex compiled from a case says of its inputs.
priv struct Outcome {
  /// Whether the pattern compiles; if it does not, nothing else is known.
  compiles : Bool
  /// For each input, in order: what `full_match` says, and what the Pike VM
  /// says.
  answers : Array[(Bool, Bool)]
  /// Whether the DFA still decides `full_match` after the last input, rather
  /// than the Pike VM it falls back to over its budget.
  by_dfa : Bool
}

///|
/// Compiles the case's pattern once and matches each input with it, with
/// `full_match` and with the Pike VM.
fn Case::run(self : Case) -> Outcome {
  let re = compile(self.text()) catch {
    _ => return { compiles: false, answers: [], by_dfa: false, }
  }
  let answers = self.inputs.map(input => {
    let bytes = joined(input)
    (re.full_match(bytes[:]), run(re.insts, bytes[:], Full).0 is Some(_))
  })
  { compiles: true, answers, by_dfa: re.dfa is Built(_), }
}

///|
/// The property: `full_match` agrees with the Pike VM on every input, and
/// its DFA, not the Pike VM it falls back to, decided them. A pattern that
/// does not compile has nothing to compare.
fn Outcome::holds(self : Outcome) -> Bool {
  !self.compiles || (self.by_dfa && self.answers.iter().all(a => a.0 == a.1))
}

///|
/// A failing case as it reads: the pattern's text, and each input with
/// both answers.
fn Case::describe(self : Case) -> String {
  let outcome = self.run()
  let out = StringBuilder()
  out.write_string("pattern \{@debug.to_string(self.text())}")
  if !outcome.compiles {
    out.write_string(" does not compile")
  } else if !outcome.by_dfa {
    out.write_string(", whose DFA was dropped")
  }
  for i, answer in outcome.answers {
    let (dfa, vm) = answer
    out.write_string("\ninput b\"")
    for byte in joined(self.inputs[i]) {
      match byte {
        b'\n' => out.write_string("\\n")
        b'"' | b'\\' => out.write_string("\\\{byte.to_char()}")
        b' '..<=b'~' => out.write_char(byte.to_char())
        _ => out.write_string("\\x\{byte.to_hex()}")
      }
    }
    out.write_string("\": full_match \{dfa}, Pike VM \{vm}")
  }
  out.to_string()
}

///|
test "full_match agrees with the Pike VM on random patterns and inputs" {
  // The outcome of the case the property passed last, which `observe` is
  // given next; no case is matched twice.
  let mut last : (Case, Outcome)? = None
  let mut compared = 0
  let mut matched = 0
  @quickcheck.check(
    (case : Case) => {
      let outcome = case.run()
      last = Some((case, outcome))
      outcome.holds()
    },
    observe=case => {
      let outcome = match last {
        Some((seen, outcome)) if physical_equal(seen, case) => outcome
        _ => case.run()
      }
      let answers = outcome.answers
      let random = answers[:@cmp.minimum(RANDOM_INPUTS, answers.length())]
      let random_matches = random.iter().filter(a => a.1).count()
      compared += random.length()
      matched += random_matches
      let spelt = answers[random.length():]
      [
        @quickcheck.classify(!outcome.compiles, "the pattern does not compile"),
        @quickcheck.classify(case.pattern.repeats(), "the pattern repeats"),
        @quickcheck.classify(
          case.pattern.alternates(),
          "the pattern alternates",
        ),
        @quickcheck.classify(
          case.pattern.has_atom(assertions),
          "the pattern asserts",
        ),
        @quickcheck.classify(
          case.pattern.has_atom(classes),
          "the pattern has a class",
        ),
        @quickcheck.classify(
          case.flags != "" || case.pattern.sets_flags(),
          "the pattern sets a flag",
        ),
        @quickcheck.classify(random_matches > 0, "a random input matches"),
        @quickcheck.classify(
          spelt.iter().any(a => a.1),
          "an input spelt from the pattern matches",
        ),
        @quickcheck.classify(
          answers.iter().any(a => !a.1),
          "an input does not match",
        ),
      ]
    },
    counterexample_context=Case::describe,
    count=3000,
    max_shrinks=1000,
    seed=FULL_MATCH_SEED,
  )
  // Enough of the random inputs match for the comparison to mean
  // something, as in the old random test.
  assert_true(matched * 20 > compared)
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
  // However a bracket class is written, it is one set of characters, which
  // CharSet keeps as "sorted, non-overlapping, non-adjacent ranges" (its doc
  // comment), so every spelling of `[a-f]` below compiles to the same
  // program: written whole, as two ranges that adjoin, as two that share
  // `d`, in the other order, and with an item inside a range and one after
  // it. The DFA is built from the program (the README's "Linear time"), and
  // Dfa::new starts a byte class "at each byte where some instruction or
  // assertion may tell it from the byte before": no instruction tells `d`
  // from `c`, nor `e` from `d`, nor `f` from `e`. So each spelling's states
  // take as much of the budget, and each drops its DFA at the same input,
  // with the Pike VM's answers before and after.
  let spellings = ["[a-f]", "[a-cd-f]", "[a-dd-f]", "[d-fa-c]", "[fa-ed]"]
  let regexes = spellings.map(class => compile("\{class}*a\{class}{14}"))
  let rand = @random.Rand::chacha8(seed=b"smock re2 dfa over its budget!!!")
  let differ = []
  for i in 0..<300 {
    let input = @buffer.Buffer()
    for _ in 0..<(15 + rand.int(limit=40)) {
      input.write_byte(if rand.int(limit=2) == 0 { b'a' } else { b'b' })
    }
    let input = input.to_bytes()
    let expected = run(regexes[0].insts, input[:], Full).0 is Some(_)
    let answers = regexes.map(re => re.full_match(input[:]))
    for j, re in regexes {
      if answers[j] != expected {
        differ.push("input \{i}: \{spellings[j]} answers otherwise")
      }
      if (re.dfa is Built(_)) != (regexes[0].dfa is Built(_)) {
        differ.push(
          "input \{i}: \{spellings[j]} drops its DFA at another input",
        )
      }
    }
  }
  debug_inspect(differ, content="[]")
  assert_true(regexes.iter().all(re => re.dfa is TooLarge))
}
