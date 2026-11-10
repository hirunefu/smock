// The record an HTTP/2 connection keeps of its client's streams: the highest
// client stream ID seen, the streams open, and the streams this side reset.
// `H2Connection::judge` (http2.mbt) holds each HEADERS frame against it
// before the `Conn` sees the frame, so that HEADERS on a stream ID already
// used end the connection whatever moonhttp does with them (RFC 9113,
// section 5.1.1). It also tells
// the count of frames that do no work which streams are closed, and which
// this side reset (`H2Connection::no_work`, http2_defences.mbt), and keeps
// the counts of the defence against Rapid Reset and MadeYouReset
// (`H2Connection::reset_early`).

///|
/// How many reset streams a connection remembers. Past it, the oldest is
/// forgotten, and HEADERS on it then end the connection, as RFC 9113,
/// section 5.1, allows: a frame that crossed the reset in flight arrives
/// long before so many other streams are reset. moonhttp 0.14.0 remembers
/// as many closed streams, reset or not, so smock still remembers every
/// reset stream that moonhttp remembers.
let remembered_resets : Int32 = 256

///|
/// Where a client stream ID stands, as the record knows it.
priv enum StreamState {
  /// Above every client stream ID seen, so not used yet.
  Idle
  /// Begun with a `Request` event, and neither reset nor ended by both
  /// sides.
  Open
  /// Reset by this side, and still remembered: by smock, through
  /// `H2Connection::reset`, or else by moonhttp, for a stream error the
  /// client's frames caused, with a `Reset` event, or by refusing a new
  /// stream at open, which it reports with no event. A new stream that
  /// moonhttp ignored after the final GOAWAY of a drain is remembered so
  /// too, since the `Conn` ignores the frames that follow on it.
  Reset
  /// Used, and neither open nor remembered as reset by this side: ended by
  /// both sides, reset by the client, skipped by a higher stream ID, or
  /// reset and forgotten.
  Closed
}

///|
/// Which sides have ended a stream that is open.
priv enum Ended {
  Neither
  ByClient
  BySmock
}

///|
/// What an HTTP/2 connection knows of its client's streams. Its memory is
/// bounded however long the connection lives: the open streams are at most
/// the concurrent-streams limit, and the reset ones at most
/// `remembered_resets`.
priv struct StreamRecord {
  /// The highest client stream ID seen in a HEADERS frame, 0 before any.
  mut highest : Int32
  /// The streams open, by ID, with the sides that have ended each.
  open : Map[Int32, Ended]
  /// The IDs of the streams this side reset, oldest first until there are
  /// `remembered_resets`; then a ring, whose oldest is at `oldest`.
  resets : Array[Int32]
  /// Once `resets` is full, the index of its oldest ID, which the next
  /// reset stream replaces.
  mut oldest : Int32
  /// A new stream whose field block has had no `Request` event yet, or 0.
  mut opening : Int32
  /// How many streams the client has begun: HEADERS on a client stream ID
  /// it had not used.
  mut begun : Int32
  /// How many of them ended reset before smock had finished their
  /// responses, as the defence against Rapid Reset and MadeYouReset counts
  /// them (`H2Connection::reset_early`).
  mut cut : Int32
  /// Whether a field block is in progress: from HEADERS without
  /// END_HEADERS until the CONTINUATION frame with it.
  mut in_block : Bool
}

///|
/// The record of a connection that has seen no stream.
fn StreamRecord::new() -> StreamRecord {
  {
    highest: 0,
    open: Map([]),
    resets: [],
    oldest: 0,
    opening: 0,
    begun: 0,
    cut: 0,
    in_block: false,
  }
}

///|
/// Where the client stream ID `id` stands.
fn StreamRecord::state(self : StreamRecord, id : Int32) -> StreamState {
  if id > self.highest {
    return Idle
  }
  if self.open.contains(id) {
    return Open
  }
  // The newest first: a frame that crossed a reset in flight is likeliest
  // to be on a stream reset lately.
  let n = self.resets.length()
  for k = 1; k <= n; k = k + 1 {
    let i = (self.oldest + n - k) % n
    if self.resets[i] == id {
      return Reset
    }
  }
  Closed
}

///|
/// Notes the frame whose header is `head`, before the `Conn` sees it, and
/// returns whether the connection goes on: not for HEADERS on a client
/// stream ID already used whose stream is neither open nor reset by this
/// side. HEADERS on a stream this side reset go to the `Conn`, which must
/// decode their field block to keep the header tables in step, and which
/// ignores them. Other frames, and stream IDs a client cannot use, are
/// left to the `Conn`.
fn StreamRecord::see(self : StreamRecord, head : @http2.FrameHeader) -> Bool {
  let ends_block = (head.flags & @http2.flag_end_headers) != 0
  if head.ftype == @http2.frame_continuation {
    if ends_block {
      self.in_block = false
    }
    return true
  }
  let id = head.stream_id
  // HEADERS inside a field block, or on an ID that only a server opens, are
  // a connection error that the `Conn` raises.
  if head.ftype != @http2.frame_headers || self.in_block || id % 2 == 0 {
    return true
  }
  match self.state(id) {
    Idle => {
      self.highest = id
      self.opening = id
      self.begun += 1
    }
    Open | Reset => ()
    Closed => return false
  }
  self.in_block = !ends_block
  true
}

///|
/// The `Conn` has reported the stream `id` with a `Request` event.
fn StreamRecord::opened(self : StreamRecord, id : Int32) -> Unit {
  if id == self.opening {
    self.opening = 0
  }
  self.open[id] = Neither
}

///|
/// How many streams are open: begun with a `Request` event, and neither
/// reset nor ended by both sides. These are the streams that count toward
/// the concurrent-streams limit (RFC 9113, section 5.1.2).
fn StreamRecord::open_count(self : StreamRecord) -> Int32 {
  self.open.length()
}

///|
/// The `Conn` has taken a frame and given all its events. A field block for
/// a new stream that has completed with no `Request` event is a stream that
/// moonhttp refused at open, which it reports with no event, or ignored
/// after the final GOAWAY of a drain: returns that stream, which the caller
/// records (`H2Connection::refused_at_open`), or 0.
fn StreamRecord::settle(self : StreamRecord) -> Int32 {
  guard self.opening != 0 && !self.in_block else { return 0 }
  let id = self.opening
  self.opening = 0
  id
}

///|
/// The client has ended the open stream `id`.
fn StreamRecord::ended_by_client(self : StreamRecord, id : Int32) -> Unit {
  match self.open.get(id) {
    Some(Neither) => self.open[id] = ByClient
    Some(BySmock) => self.open.remove(id)
    _ => ()
  }
}

///|
/// smock has ended the open stream `id`.
fn StreamRecord::ended_by_smock(self : StreamRecord, id : Int32) -> Unit {
  match self.open.get(id) {
    Some(Neither) => self.open[id] = BySmock
    Some(ByClient) => self.open.remove(id)
    _ => ()
  }
}

///|
/// Whether smock has yet to finish its response on the open stream `id`:
/// it has not ended the stream from its side.
fn StreamRecord::unfinished(self : StreamRecord, id : Int32) -> Bool {
  self.open.get(id) is Some(Neither | ByClient)
}

///|
/// The client has reset the open stream `id`.
fn StreamRecord::reset_by_client(self : StreamRecord, id : Int32) -> Unit {
  self.open.remove(id)
}

///|
/// This side has reset the stream `id`, smock or moonhttp, or moonhttp
/// ignored the new stream `id` after the final GOAWAY of a drain. The
/// oldest such stream is forgotten once there are `remembered_resets`.
fn StreamRecord::remember(self : StreamRecord, id : Int32) -> Unit {
  self.open.remove(id)
  if self.resets.length() < remembered_resets {
    self.resets.push(id)
  } else {
    self.resets[self.oldest] = id
    self.oldest = (self.oldest + 1) % remembered_resets
  }
}
