///|
/// How `run` matches: `Full` needs a match of the whole input, `Search` looks
/// for the leftmost match.
priv enum Mode {
  Full
  Search
} derive(Eq)

///|
/// The threads at one input position, in priority order, with the input
/// position each thread started at. A sparse set keyed by instruction index,
/// so each instruction holds at most one thread.
priv struct Threads {
  dense : FixedArray[Int]
  sparse : FixedArray[Int]
  starts : FixedArray[Int]
  mut size : Int
}

///|
fn Threads::new(n : Int) -> Threads {
  {
    dense: FixedArray::make(n, 0),
    sparse: FixedArray::make(n, 0),
    starts: FixedArray::make(n, 0),
    size: 0,
  }
}

///|
fn Threads::contains(self : Threads, pc : Int) -> Bool {
  let i = self.sparse[pc]
  i < self.size && self.dense[i] == pc
}

///|
fn Threads::insert(self : Threads, pc : Int, start : Int) -> Unit {
  self.sparse[pc] = self.size
  self.dense[self.size] = pc
  self.starts[self.size] = start
  self.size += 1
}

///|
/// Runs `prog` over `input` as a Pike VM: every thread advances in lockstep,
/// one code point at a time, so the work per input position is bounded by
/// the program size and never depends on what came before. Returns the match
/// and the number of steps taken (one per instruction a thread visits).
fn run(prog : Prog, input : BytesView, mode : Mode) -> (Match?, Int) {
  let n = prog.insts.length()
  let len = input.length()
  let mut clist = Threads::new(n)
  let mut nlist = Threads::new(n)
  let stack : Array[Int] = []
  let mut steps = 0
  let mut matched : Match? = None
  // Adds the thread at `pc` and every thread reachable from it without
  // consuming input, in priority order.
  fn add(list : Threads, pc : Int, start : Int, at : Int) {
    stack.push(pc)
    while stack.pop() is Some(pc) {
      if list.contains(pc) {
        continue
      }
      list.insert(pc, start)
      steps += 1
      match prog.insts[pc] {
        Assert(a) => if holds(a, input, at) { stack.push(pc + 1) }
        Jmp(x) => stack.push(x)
        Split(x, y) => {
          // Pushed in reverse, so `x` and everything it reaches comes first.
          stack.push(y)
          stack.push(x)
        }
        _ => ()
      }
    }
  }

  let mut pos = 0
  for ;; {
    if matched is None && (mode == Search || pos == 0) {
      add(clist, 0, pos, pos)
    }
    if clist.size == 0 && (matched is Some(_) || mode == Full) {
      break
    }
    let (c, width) = if pos < len {
      decode(input, pos)
    } else {
      (not_a_char, 0)
    }
    for i in 0..<clist.size {
      let pc = clist.dense[i]
      let start = clist.starts[i]
      steps += 1
      match prog.insts[pc] {
        Match =>
          if mode == Full {
            if pos == len {
              return (Some({ start, end: pos, }), steps)
            }
          } else {
            matched = Some({ start, end: pos, })
            break
          }
        Char(x) => if x == c { add(nlist, pc + 1, start, pos + width) }
        Class(set) =>
          if set.contains(c) {
            add(nlist, pc + 1, start, pos + width)
          }
        Assert(_) | Split(_, _) | Jmp(_) => ()
      }
    }
    if pos >= len {
      break
    }
    pos += width
    let t = clist
    clist = nlist
    nlist = t
    nlist.size = 0
  }
  (matched, steps)
}

///|
/// Reports whether `a` holds at byte offset `at` of `input`.
fn holds(a : Assertion, input : BytesView, at : Int) -> Bool {
  match a {
    BeginText => at == 0
    EndText => at == input.length()
    BeginLine => at == 0 || input[at - 1] == b'\n'
    EndLine => at == input.length() || input[at] == b'\n'
    WordBoundary => is_word_byte(input, at - 1) != is_word_byte(input, at)
    NotWordBoundary => is_word_byte(input, at - 1) == is_word_byte(input, at)
  }
}

///|
/// Reports whether the byte at `i` is an ASCII word character, `[0-9A-Za-z_]`.
/// Bytes outside the input are not. No byte of a multi-byte UTF-8 sequence
/// is, so this is the same as asking about the code point.
fn is_word_byte(input : BytesView, i : Int) -> Bool {
  if i < 0 || i >= input.length() {
    return false
  }
  let b = input[i]
  (b >= b'0' && b <= b'9') ||
  (b >= b'A' && b <= b'Z') ||
  (b >= b'a' && b <= b'z') ||
  b == b'_'
}
