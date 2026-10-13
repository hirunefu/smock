// A DFA for `full_match`, built lazily from the compiled program as inputs
// need its states, and cached in the `Regex`.
//
// `full_match` only asks whether some way through the program spans the
// whole input, not which one, so the set of instructions the Pike VM's
// threads are at is all that matters, and equal sets behave alike. Each DFA
// state is such a set: the instructions the threads are at right after a
// character is consumed, before jumps, splits and assertions are followed,
// together with what the assertions need to know about that character.
// Following those and consuming the next character gives the next state,
// which is computed once and then looked up. A state with no thread left is
// dead: nothing matches any more.
//
// The cache is bounded. When a regex needs more states than the budget
// allows, it drops its DFA and matches with the Pike VM from then on. Each
// state costs work bounded by the program size, once, so matching stays
// linear in the length of the input either way.

///|
/// What is on one side of a position of the input, as far as assertions
/// can tell: the start or the end of the input, a `\n`, an ASCII word
/// character, or anything else (another character, or a byte of ill-formed
/// UTF-8).
const EDGE : Int = 0

///|
const NEWLINE : Int = 1

///|
const WORD : Int = 2

///|
const OTHER : Int = 3

///|
/// The dead state, which has no thread left.
const DEAD : Int = 0

///|
/// The state at the start of the input.
const START : Int = 1

///|
/// The most Ints a DFA may hold in its transition table and its states
/// together (128 KiB). Past it, the regex matches with the Pike VM.
const DFA_BUDGET : Int = 32768

///|
/// The DFA of one program.
priv struct Dfa {
  insts : FixedArray[Inst]
  /// Whether the program has assertions. Without any, the context of a
  /// position never matters, and states are not told apart by it.
  asserts : Bool
  /// The class of each ASCII byte: no instruction and no assertion tells
  /// the bytes of one class apart, so they lead from a state to the same
  /// state.
  byte_class : FixedArray[Int]
  /// The number of byte classes.
  classes : Int
  /// Each state, as the instructions its threads are at, sorted, followed
  /// by the context the last character consumed leaves (`EDGE` at the
  /// start of the input).
  states : Array[Array[Int]]
  /// The number of each state.
  numbers : Map[Array[Int], Int]
  /// The next state of each state for each byte class, at
  /// `state * classes + class`; -1 until it is computed.
  table : Array[Int]
  /// The next state of each state for each character beyond ASCII, at
  /// `state * 0x110000 + character`.
  wide : Map[Int64, Int]
  /// Whether the input may end in each state: 1 if so, 0 if not, -1 until
  /// it is computed.
  accepts : Array[Int]
  /// The Ints the states and the table hold.
  mut size : Int
  /// Scratch space: the stamp each instruction got last, the instructions
  /// to visit, and those reached.
  seen : FixedArray[Int]
  mut stamp : Int
  stack : Array[Int]
  reached : Array[Int]
}

///|
/// The DFA of `insts`, with only its dead state and its start state built.
fn Dfa::new(insts : FixedArray[Inst]) -> Dfa {
  let asserts = insts.iter().any(inst => inst is Assert(_))
  // A class starts at each byte where some instruction or assertion may
  // tell it from the byte before.
  let starts = FixedArray::make(129, false)
  starts[0] = true
  let split = (lo : Int, hi : Int) => {
    if lo < 128 && hi >= 0 {
      starts[if lo < 0 { 0 } else { lo }] = true
      if hi < 127 {
        starts[hi + 1] = true
      }
    }
  }
  for inst in insts {
    match inst {
      Char(c) => split(c, c)
      Class(set) =>
        for i = 0; i < set.ranges.length(); i = i + 2 {
          split(set.ranges[i], set.ranges[i + 1])
        }
      _ => ()
    }
  }
  if asserts {
    split('\n'.to_int(), '\n'.to_int())
    split('0'.to_int(), '9'.to_int())
    split('A'.to_int(), 'Z'.to_int())
    split('_'.to_int(), '_'.to_int())
    split('a'.to_int(), 'z'.to_int())
  }
  let byte_class = FixedArray::make(128, 0)
  let mut class = -1
  for b in 0..<128 {
    if starts[b] {
      class += 1
    }
    byte_class[b] = class
  }
  let dfa = {
    insts,
    asserts,
    byte_class,
    classes: class + 1,
    states: [],
    numbers: Map([]),
    table: [],
    wide: Map([]),
    accepts: [],
    size: 0,
    seen: FixedArray::make(insts.length() + 1, 0),
    stamp: 0,
    stack: [],
    reached: [],
  }
  dfa.add([]) |> ignore
  dfa.add([0, EDGE]) |> ignore
  dfa
}

///|
/// The number of the state `key`, added if it is new, or -1 when adding it
/// would take the DFA over its budget.
fn Dfa::add(self : Dfa, key : Array[Int]) -> Int {
  if self.numbers.get(key) is Some(number) {
    return number
  }
  if self.size + key.length() + self.classes > DFA_BUDGET {
    return -1
  }
  let number = self.states.length()
  self.states.push(key)
  self.numbers[key] = number
  self.size += key.length() + self.classes
  // The dead state stays dead, whatever comes.
  let next = if number == DEAD { DEAD } else { -1 }
  for _ in 0..<self.classes {
    self.table.push(next)
  }
  self.accepts.push(if number == DEAD { 0 } else { -1 })
  number
}

///|
/// What a character leaves on its side of a position, for assertions.
fn context_of(c : Int) -> Int {
  if c == '\n'.to_int() {
    NEWLINE
  } else if (c >= '0'.to_int() && c <= '9'.to_int()) ||
    (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
    (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
    c == '_'.to_int() {
    WORD
  } else {
    OTHER
  }
}

///|
/// Whether `a` holds at a position with `before` on one side and `after`
/// on the other, as `holds` decides it from the input.
fn holds_between(a : Assertion, before : Int, after : Int) -> Bool {
  match a {
    BeginText => before == EDGE
    EndText => after == EDGE
    BeginLine => before == EDGE || before == NEWLINE
    EndLine => after == EDGE || after == NEWLINE
    WordBoundary => (before == WORD) != (after == WORD)
    NotWordBoundary => (before == WORD) == (after == WORD)
  }
}

///|
/// Follows the jumps, splits and assertions from the threads of `state`,
/// where `after` follows, into `self.reached`: the instructions that
/// consume a character or match.
fn Dfa::follow(self : Dfa, state : Int, after : Int) -> Unit {
  let key = self.states[state]
  let before = key[key.length() - 1]
  self.stamp += 1
  self.reached.clear()
  for i in 0..<(key.length() - 1) {
    self.stack.push(key[i])
  }
  while self.stack.pop() is Some(pc) {
    if self.seen[pc] == self.stamp {
      continue
    }
    self.seen[pc] = self.stamp
    match self.insts[pc] {
      Jmp(x) => self.stack.push(x)
      Split(x, y) => {
        self.stack.push(x)
        self.stack.push(y)
      }
      Assert(a) =>
        if holds_between(a, before, after) {
          self.stack.push(pc + 1)
        }
      Char(_) | Class(_) | Match => self.reached.push(pc)
    }
  }
}

///|
/// The state after `state` consumes the character `c`, or -1 when it would
/// take the DFA over its budget.
fn Dfa::step(self : Dfa, state : Int, c : Int) -> Int {
  let context = context_of(c)
  self.follow(state, context)
  self.stamp += 1
  let key = []
  for pc in self.reached {
    let consumes = match self.insts[pc] {
      Char(x) => x == c
      Class(set) => set.contains(c)
      _ => false
    }
    if consumes && self.seen[pc + 1] != self.stamp {
      self.seen[pc + 1] = self.stamp
      key.push(pc + 1)
    }
  }
  if key.is_empty() {
    return DEAD
  }
  key.sort()
  key.push(if self.asserts { context } else { EDGE })
  self.add(key)
}

///|
/// Whether the input may end in `state`: a thread matches there.
fn Dfa::accepts_at_end(self : Dfa, state : Int) -> Bool {
  if self.accepts[state] < 0 {
    self.follow(state, EDGE)
    let matches = self.reached.iter().any(pc => self.insts[pc] is Match)
    self.accepts[state] = if matches { 1 } else { 0 }
  }
  self.accepts[state] == 1
}

///|
/// Whether the program matches the whole of `input`, or `None` when
/// deciding it would take the DFA over its budget.
fn Dfa::full_match(self : Dfa, input : BytesView) -> Bool? {
  let len = input.length()
  let mut state = START
  let mut pos = 0
  while pos < len {
    let b = input[pos].to_int()
    let mut next = 0
    if b < 0x80 {
      let cell = state * self.classes + self.byte_class[b]
      next = self.table[cell]
      if next < 0 {
        next = self.step(state, b)
        if next < 0 {
          return None
        }
        self.table[cell] = next
      }
      pos += 1
    } else {
      let (c, width) = decode(input, pos)
      // Nothing consumes a byte that is not part of well-formed UTF-8.
      if c == not_a_char {
        return Some(false)
      }
      let key = state.to_int64() * 0x110000L + c.to_int64()
      next = match self.wide.get(key) {
        Some(next) => next
        None => {
          let next = self.step(state, c)
          // An entry of the map counts as four Ints.
          if next < 0 || self.size + 4 > DFA_BUDGET {
            return None
          }
          self.size += 4
          self.wide[key] = next
          next
        }
      }
      pos += width
    }
    if next == DEAD {
      return Some(false)
    }
    state = next
  }
  Some(self.accepts_at_end(state))
}
