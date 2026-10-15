///|
/// One instruction of a compiled program.
priv enum Inst {
  /// Consumes the code point.
  Char(Int)
  /// Consumes a code point of the set.
  Class(CharSet)
  /// Continues only where the assertion holds.
  Assert(Assertion)
  /// Continues at both, preferring the first.
  Split(Int, Int)
  /// Continues at the instruction.
  Jmp(Int)
  /// The pattern matched.
  Match
}

///|
/// The most instructions a compiled program may have. Like RE2's memory
/// budget, it bounds the time and memory that compiling and matching take.
const MAX_PROGRAM_SIZE : Int = 100000

///|
/// Builds a program, one instruction at a time.
priv struct Compiler {
  insts : Array[Inst]
}

///|
/// The program that matches `node`, ending with `Match`.
fn compile_node(node : Node) -> FixedArray[Inst] raise CompileError {
  let c : Compiler = { insts: [], }
  c.emit(node)
  c.push(Match) |> ignore
  FixedArray::from_array(c.insts)
}

///|
/// Appends `inst` and returns its index.
fn Compiler::push(self : Compiler, inst : Inst) -> Int raise CompileError {
  if self.insts.length() >= MAX_PROGRAM_SIZE {
    fail_at(
      0,
      "pattern too large: it compiles to more than \{MAX_PROGRAM_SIZE} instructions",
    )
  }
  self.insts.push(inst)
  self.insts.length() - 1
}

///|
/// Appends a placeholder instruction, to be patched once its targets are
/// known, and returns its index.
fn Compiler::placeholder(self : Compiler) -> Int raise CompileError {
  self.push(Match)
}

///|
/// Patches the placeholder at `at` into a split whose preferred branch is the
/// next instruction when greedy and `other` when lazy.
fn Compiler::patch_split(
  self : Compiler,
  at : Int,
  other : Int,
  greedy : Bool,
) -> Unit {
  self.insts[at] = if greedy {
    Split(at + 1, other)
  } else {
    Split(other, at + 1)
  }
}

///|
fn Compiler::emit(self : Compiler, node : Node) -> Unit raise CompileError {
  match node {
    Empty => ()
    Literal(c) => self.push(Char(c)) |> ignore
    Class(set) => self.push(Class(set)) |> ignore
    Assert(a) => self.push(Assert(a)) |> ignore
    Concat(items) =>
      for item in items {
        self.emit(item)
      }
    Alternate(alternatives) => {
      let jumps = []
      for i in 0..<(alternatives.length() - 1) {
        let at = self.placeholder()
        self.emit(alternatives[i])
        jumps.push(self.placeholder())
        self.patch_split(at, self.insts.length(), true)
      }
      self.emit(alternatives[alternatives.length() - 1])
      for j in jumps {
        self.insts[j] = Jmp(self.insts.length())
      }
    }
    Repeat(sub, min~, max~, greedy~, ..) => {
      let (sub_nullable, _) = info(sub)
      self.emit_repeat(sub, sub_nullable, min, max, greedy)
    }
  }
}

///|
/// x+
fn Compiler::emit_plus(
  self : Compiler,
  sub : Node,
  greedy : Bool,
) -> Unit raise CompileError {
  let begin = self.insts.length()
  self.emit(sub)
  let at = self.insts.length()
  self.push(if greedy { Split(begin, at + 1) } else { Split(at + 1, begin) })
  |> ignore
}

///|
/// x*. When x can match the empty string, one loop would put RE2's
/// preferences in the wrong order, so x* is compiled as (x+)?, as RE2 does.
fn Compiler::emit_star(
  self : Compiler,
  sub : Node,
  sub_nullable : Bool,
  greedy : Bool,
) -> Unit raise CompileError {
  let at = self.placeholder()
  if sub_nullable {
    self.emit_plus(sub, greedy)
  } else {
    self.emit(sub)
    self.push(Jmp(at)) |> ignore
  }
  self.patch_split(at, self.insts.length(), greedy)
}

///|
/// x{min,max}, expanded as RE2 does: x{2,} is xx+ and x{2,5} is
/// xx(x(x(x)?)?)?.
fn Compiler::emit_repeat(
  self : Compiler,
  sub : Node,
  sub_nullable : Bool,
  min : Int,
  max : Int?,
  greedy : Bool,
) -> Unit raise CompileError {
  guard max is Some(max) else {
    match min {
      0 => self.emit_star(sub, sub_nullable, greedy)
      1 => self.emit_plus(sub, greedy)
      _ => {
        for _ in 0..<(min - 1) {
          self.emit(sub)
        }
        self.emit_plus(sub, greedy)
      }
    }
    return
  }
  for _ in 0..<min {
    self.emit(sub)
  }
  let splits = []
  for _ in 0..<(max - min) {
    splits.push(self.placeholder())
    self.emit(sub)
  }
  for at in splits {
    self.patch_split(at, self.insts.length(), greedy)
  }
}
