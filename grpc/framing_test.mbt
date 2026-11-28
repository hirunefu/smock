// gRPC's message framing through the module's public interface: the
// 5-octet prefix, a flag and a 4-octet big-endian length, before each
// message (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md),
// read as a body arrives, in pieces split anywhere, with bodies that end
// inside a prefix or inside a message.

///|
/// What a deframer makes of a body fed in `pieces`: each prefix it reads,
/// as its flag, its message's length and the body's length through that
/// message, then how the body ends.
fn framing(pieces : Array[BytesView]) -> String {
  let deframer = @grpc.Deframer()
  let out = []
  for piece in pieces {
    let mut rest = piece
    while deframer.take(rest)
          is Prefix(flag~, length~, body_length~, rest=after) {
      out.push(
        "prefix: flag \{flag.to_int()}, \{length} octets, the body \{body_length} octets through them",
      )
      rest = after
    }
  }
  let ending = match deframer.ending() {
    Whole(messages~) => "ends after \{messages} messages"
    InPrefix => "ends inside a prefix"
    InMessage(length~) => "ends inside a message of \{length} octets"
  }
  out.push(ending)
  out.join("\n")
}

///|
/// What a deframer makes of `body` fed whole.
fn whole(body : Bytes) -> String {
  framing([body[:]])
}

///|
test "a message is a flag, its length in 4 octets big-endian, then its octets" {
  inspect(
    whole(b"\x00\x00\x00\x00\x05\x0a\x03Tom"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends after 1 messages
    ),
  )
}

///|
test "a body may hold several messages, empty ones and compressed ones included" {
  inspect(
    whole(b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02ab\x00\x00\x00\x00\x01c"),
    content=(
      #|prefix: flag 0, 0 octets, the body 5 octets through them
      #|prefix: flag 1, 2 octets, the body 12 octets through them
      #|prefix: flag 0, 1 octets, the body 18 octets through them
      #|ends after 3 messages
    ),
  )
}

///|
test "an empty body holds no message" {
  inspect(whole(b""), content="ends after 0 messages")
  inspect(framing([]), content="ends after 0 messages")
}

///|
test "a body that ends inside a prefix, at any octet of it, is told apart" {
  let prefix = b"\x00\x00\x00\x00\x05"
  for n in 1..<5 {
    inspect(whole(prefix[0:n].to_owned()), content="ends inside a prefix")
  }
  inspect(
    whole(b"\x00\x00\x00\x00\x01a\x00\x00"),
    content=(
      #|prefix: flag 0, 1 octets, the body 6 octets through them
      #|ends inside a prefix
    ),
  )
}

///|
test "a body that ends inside a message gives the length its prefix announced" {
  inspect(
    whole(b"\x00\x00\x00\x00\x05\x0a\x03T"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends inside a message of 5 octets
    ),
  )
  inspect(
    whole(b"\x00\x00\x00\x00\x05"),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends inside a message of 5 octets
    ),
  )
}

///|
test "a length past any body is read whole, as an unsigned number, as soon as its prefix arrives" {
  inspect(
    whole(b"\x00\x00\x00\x00\x01a\x00\xff\xff\xff\xff"),
    content=(
      #|prefix: flag 0, 1 octets, the body 6 octets through them
      #|prefix: flag 0, 4294967295 octets, the body 4294967306 octets through them
      #|ends inside a message of 4294967295 octets
    ),
  )
}

///|
test "a flag is passed on as it is, whatever its value" {
  inspect(
    whole(b"\x80\x00\x00\x00\x00\xff\x00\x00\x00\x00"),
    content=(
      #|prefix: flag 128, 0 octets, the body 5 octets through them
      #|prefix: flag 255, 0 octets, the body 10 octets through them
      #|ends after 2 messages
    ),
  )
}

///|
/// Bodies that use every way a body is framed or ends: messages of no
/// octet, of one and of several, compressed ones, other flags, and bodies
/// that end inside a prefix or inside a message.
let bodies : Array[Bytes] = [
  b"\x00\x00\x00\x00\x05\x0a\x03Tom", b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02ab\x00\x00\x00\x00\x01c",
  b"\x00\x00\x00\x00\x00", b"\x02\x00\x00\x00\x03xyz\x00\x00\x00\x01\x00", b"\x00\x00\x00\x00\x01a\x00\x00",
  b"\x00\x00\x00\x01\x00abc", b"\x00\x00\x00\x00\x02ab\x00\xff\xff\xff\xff\x00",
]

///|
test "a body split in two at any octet is read as when it comes whole" {
  for body in bodies {
    let expected = whole(body)
    for i in 0..<=body.length() {
      let split = framing([body[:i], body[i:]])
      guard split == expected else {
        fail(
          "\{@hex.encode(body)} split at \{i}:\n\{split}\nwhole:\n\{expected}",
        )
      }
    }
  }
}

///|
test "a body that comes one octet at a time, or in three pieces split anywhere, is read as when it comes whole" {
  for body in bodies {
    let expected = whole(body)
    let octets = []
    for i in 0..<body.length() {
      octets.push(body[i:i + 1])
    }
    assert_eq(framing(octets), expected)
    for i in 0..<=body.length() {
      for j in i..<=body.length() {
        let split = framing([body[:i], body[i:j], body[j:]])
        guard split == expected else {
          fail("\{@hex.encode(body)} split at \{i} and \{j}:\n\{split}")
        }
      }
    }
  }
}

///|
test "framing a message gives flag 0, its length and its octets, which read back" {
  let framed = @grpc.frame(b"\x0a\x03Tom"[:])
  inspect(@hex.encode(framed), content="00000000050a03546f6d")
  inspect(@hex.encode(@grpc.frame(b""[:])), content="0000000000")
  inspect(
    whole(framed),
    content=(
      #|prefix: flag 0, 5 octets, the body 10 octets through them
      #|ends after 1 messages
    ),
  )
  // PROTOCOL-HTTP2, Requests: Message-Length is the message's length
  // "encoded as 4 byte unsigned integer (big endian)". So a message of 255
  // octets carries 00 00 00 ff; one of 256, the first length one octet
  // cannot hold, 00 00 01 00; and ones of 65,536 and 16,777,216, the first
  // lengths that need a third and a fourth octet, 00 01 00 00 and
  // 01 00 00 00. Each prefix starts with flag 0, after which the message
  // is as it is (Compressed-Flag).
  let out = []
  for length in [255, 256, 65_536, 16_777_216] {
    let message = Bytes::make(length, b'\x2a')
    let framed = @grpc.frame(message[:])
    assert_true(framed[@grpc.prefix_length:] == message[:])
    out.push("\{length} octets: \{@hex.encode(framed[:@grpc.prefix_length])}")
    out.push(whole(framed))
  }
  inspect(
    out.join("\n"),
    content=(
      #|255 octets: 00000000ff
      #|prefix: flag 0, 255 octets, the body 260 octets through them
      #|ends after 1 messages
      #|256 octets: 0000000100
      #|prefix: flag 0, 256 octets, the body 261 octets through them
      #|ends after 1 messages
      #|65536 octets: 0000010000
      #|prefix: flag 0, 65536 octets, the body 65541 octets through them
      #|ends after 1 messages
      #|16777216 octets: 0001000000
      #|prefix: flag 0, 16777216 octets, the body 16777221 octets through them
      #|ends after 1 messages
    ),
  )
}

///|
test "the messages that have arrived whole are counted as each one's last octet arrives, a message of zero octets as soon as its prefix does" {
  let deframer = @grpc.Deframer()
  let counts = []
  // HelloRequest { name: "Tom" }, an empty message, then a message cut
  // short, one octet at a time.
  let body = b"\x00\x00\x00\x00\x05\x0a\x03Tom\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02a"
  counts.push(deframer.whole_messages())
  for i in 0..<body.length() {
    let mut rest = body[i:i + 1]
    while deframer.take(rest) is Prefix(rest=after, ..) {
      rest = after
    }
    counts.push(deframer.whole_messages())
  }
  inspect(
    counts.map(count => count.to_string()).join(""),
    content="0000000000111112222222",
  )
  debug_inspect(deframer.ending(), content="InMessage(length=2)")
}

///|
/// The seed of the property that a message framed and read back by the
/// deframer gives the message. The tests run with it on every push, in
/// mutation runs and in kill confirmations, so a failure reproduces. Each
/// week, `scripts/random-seeds.py` writes a random seed here in a working
/// copy and prints it (CONTRIBUTING.md, "Seeds").
const FRAMING_SEED : UInt64 = 10444929829213460537

///|
/// The messages of a body and where the body is cut into the pieces it
/// arrives in: each cut is an offset into the framed body, and offsets past
/// its end, which a smaller body may leave, cut at the end.
priv struct Body {
  messages : Array[Bytes]
  cuts : Array[Int32]
}

///|
/// A message as a failure shows it: its length, and its first 16 octets in
/// hex, so that a message of 65,536 octets takes one line.
fn shown(message : BytesView) -> String {
  if message.length() <= 16 {
    "\{message.length()} octets \{@hex.encode(message)}"
  } else {
    "\{message.length()} octets \{@hex.encode(message[:16])}..."
  }
}

///|
/// A body as a failure shows it: each message shown, then the cuts.
impl @debug.Debug for Body with fn to_repr(self) {
  let messages = self.messages.map(message => shown(message[:]))
  @debug.Repr::literal(
    "messages \{@debug.to_string(messages)}, cut at \{@debug.to_string(self.cuts)}",
  )
}

///|
/// The index of a random one of `n` choices.
fn below(state : @quickcheck.RandomState, n : Int32) -> Int32 {
  state.next_uint(limit=n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// A random message: empty, short, of 250 to 260 octets, around 256, the
/// first length whose Message-Length needs a second octet, or of 65,530 to
/// 65,540, around 65,536, the first that needs a third. The octets of the
/// shorter ones are random, so they may look like a prefix; a long one
/// repeats one random octet.
fn random_message(state : @quickcheck.RandomState) -> Bytes {
  match below(state, 8) {
    0 | 1 => Bytes::new(0)
    2 | 3 | 4 =>
      Bytes::makei(1 + below(state, 16), _ => below(state, 256).to_byte())
    5 | 6 =>
      Bytes::makei(250 + below(state, 11), _ => below(state, 256).to_byte())
    _ => Bytes::make(65_530 + below(state, 11), below(state, 256).to_byte())
  }
}

///|
/// The body: `@grpc.frame` of each message, one after another.
fn Body::framed(self : Body) -> Bytes {
  let out = @buffer.Buffer()
  for message in self.messages {
    out.write_bytes(@grpc.frame(message[:]))
  }
  out.to_bytes()
}

///|
/// Up to four messages, and up to six cuts anywhere in the framed body.
impl @quickcheck.Arbitrary for Body with fn arbitrary(_size, state) {
  let messages = Array::makei(below(state, 5), _ => random_message(state))
  let length = { messages, cuts: [], }.framed().length()
  let cuts = Array::makei(below(state, 7), _ => below(state, length + 1))
  cuts.sort()
  { messages, cuts, }
}

///|
/// Smaller bodies: each without one of its messages, each with a message
/// cut to half its length or one octet shorter, or with its first octet
/// that is not 0 made 0, and each without one of its cuts. Each has fewer
/// messages, octets, octets that are not 0 or cuts, and no more of the
/// others, so shrinking ends.
impl @quickcheck.Shrink for Body with fn shrink(self) {
  let out : Array[Body] = []
  let messages = self.messages
  for i in 0..<messages.length() {
    let rest = messages.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, messages: rest, })
  }
  for i, message in messages {
    if message.length() > 1 {
      let changed = messages.copy()
      changed[i] = message[:message.length() / 2].to_owned()
      out.push({ ..self, messages: changed, })
    }
    if message.length() > 0 {
      let changed = messages.copy()
      changed[i] = message[:message.length() - 1].to_owned()
      out.push({ ..self, messages: changed, })
    }
    for j, octet in message {
      if octet != b'\x00' {
        let changed = messages.copy()
        changed[i] = Bytes::makei(message.length(), k => {
          if k == j {
            b'\x00'
          } else {
            message[k]
          }
        })
        out.push({ ..self, messages: changed, })
        break
      }
    }
  }
  for i in 0..<self.cuts.length() {
    let rest = self.cuts.copy()
    rest.remove(i) |> ignore
    out.push({ ..self, cuts: rest, })
  }
  out.iter()
}

///|
/// What a reader built on the deframer makes of a body: each prefix it
/// reads, as its flag, its message's length, the body's length through the
/// message and the offset where the prefix ends; the message read back, the
/// octets after that offset that the length announced; then how the body
/// ends and how many messages are whole.
priv struct ReadBack {
  prefixes : Array[(Byte, UInt32, Int64, Int32)]
  messages : Array[Bytes]
  ending : @grpc.Ending
  whole : Int32
}

///|
/// Feeds the framed body to a deframer in the pieces its cuts make, and
/// reads each message back from where its prefix ends.
fn Body::read_back(self : Body) -> ReadBack {
  let framed = self.framed()
  let deframer = @grpc.Deframer()
  let prefixes = []
  let mut from = 0
  for cut in [..self.cuts, framed.length()] {
    let to = if cut < from {
      from
    } else if cut > framed.length() {
      framed.length()
    } else {
      cut
    }
    let mut rest = framed[from:to]
    while deframer.take(rest)
          is Prefix(flag~, length~, body_length~, rest=after) {
      prefixes.push((flag, length, body_length, after.start_offset()))
      rest = after
    }
    from = to
  }
  let messages = prefixes.map(prefix => {
    let (_, length, _, at) = prefix
    let end = at.to_int64() + length.to_uint64().reinterpret_as_int64()
    if end <= framed.length().to_int64() {
      framed[at:end.to_int()].to_owned()
    } else {
      framed[at:].to_owned()
    }
  })
  {
    prefixes,
    messages,
    ending: deframer.ending(),
    whole: deframer.whole_messages(),
  }
}

///|
/// The property, by PROTOCOL-HTTP2's Length-Prefixed-Message
/// (Compressed-Flag, Message-Length "encoded as 4 byte unsigned integer
/// (big endian)", Message): the deframer reads one prefix for each message,
/// in order, with flag 0, the message's length, and the body's length
/// through the message; the length's octets after the prefix are the
/// message; and the body ends whole after as many messages, all of them
/// whole.
fn Body::holds(self : Body) -> Bool {
  let read = self.read_back()
  let n = self.messages.length()
  guard read.prefixes.length() == n else { return false }
  let mut through = 0L
  for i, message in self.messages {
    let (flag, length, body_length, at) = read.prefixes[i]
    through += (@grpc.prefix_length + message.length()).to_int64()
    guard flag == b'\x00' &&
      length == message.length().reinterpret_as_uint() &&
      body_length == through &&
      at.to_int64() + length.to_uint64().reinterpret_as_int64() == through &&
      read.messages[i] == message else {
      return false
    }
  }
  read.ending == Whole(messages=n) && read.whole == n
}

///|
/// What the reader made of a failing body: each prefix, each message read
/// back, shown, how the body ends and how many messages are whole.
fn Body::describe(self : Body) -> String {
  let read = self.read_back()
  let messages = read.messages.map(message => shown(message[:]))
  "prefixes (flag, length, body length, end) \{@debug.to_string(read.prefixes)}, messages read back \{@debug.to_string(messages)}, \{@debug.to_string(read.ending)}, \{read.whole} whole"
}

///|
test "a message framed and read back by the deframer gives the message, whatever pieces the body arrives in" {
  @quickcheck.check(
    (body : Body) => body.holds(),
    observe=body => {
      // Where each prefix starts in the framed body.
      let starts = []
      let mut at = 0
      for message in body.messages {
        starts.push(at)
        at += @grpc.prefix_length + message.length()
      }
      let inside = (from : Int32, to : Int32) => {
        body.cuts.iter().any(cut => cut > from && cut < to)
      }
      [
        @quickcheck.classify(body.messages.is_empty(), "no message"),
        @quickcheck.classify(body.messages.length() > 1, "several messages"),
        @quickcheck.classify(
          body.messages.iter().any(message => message.length() == 0),
          "an empty message",
        ),
        @quickcheck.classify(
          body.messages.iter().any(message => message.length() >= 256),
          "a message of 256 octets or more",
        ),
        @quickcheck.classify(
          body.messages.iter().any(message => message.length() >= 65_536),
          "a message of 65,536 octets or more",
        ),
        @quickcheck.classify(
          starts.iter().any(start => inside(start, start + @grpc.prefix_length)),
          "a piece ends inside a prefix",
        ),
        @quickcheck.classify(
          body.messages
          .iter()
          .zip(starts.iter())
          .any(pair => {
            let (message, start) = pair
            let from = start + @grpc.prefix_length
            inside(from, from + message.length())
          }),
          "a piece ends inside a message",
        ),
      ]
    },
    counterexample_context=Body::describe,
    count=1000,
    max_shrinks=1000,
    seed=FRAMING_SEED,
  )
}
