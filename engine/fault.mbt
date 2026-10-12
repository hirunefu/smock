// Fault decisions: whether a matched request is delayed and for how long,
// and whether its connection fails. They draw from the Stub's own
// generator when it has a seed, and otherwise from the process generator.

///|
/// The generators of the Stubs of `snapshot` that have a seed, by Stub ID,
/// each created from its seed.
fn seeded_generators(
  snapshot : @definitions.Snapshot,
) -> Map[String, @prng.Generator] {
  let generators = Map([])
  for mock in snapshot.mocks {
    for stub in mock.stubs {
      if stub.fault is Some({ seed: Some(seed), .. }) {
        generators[stub.id] = @prng.Generator(seed)
      }
    }
  }
  generators
}

///|
/// The Fault decisions for one request that `stub` matched: the delay, in
/// milliseconds, and the connection Fault, if any. They draw from `source`:
/// the Stub's own generator, or else the process generator.
///
/// The source advances exactly once per matched request: every draw for
/// the request comes from a generator split off it. So the n-th matched
/// request of a seeded Stub gets the same decisions in every run, whatever
/// other Stubs do, and whatever earlier requests drew.
fn decide_faults(
  stub : @definitions.Stub,
  source : @prng.Generator,
) -> (Int, ConnectionFault?) {
  guard stub.fault is Some(fault) &&
    (fault.delay is Some(_) || fault.connection is Some(_)) else {
    return (0, None)
  }
  let draws = source.split()
  let delay_ms = match fault.delay {
    Some(delay) if draws.double() < delay.probability =>
      sample(delay.distribution, draws)
    _ => 0
  }
  let connection = match fault.connection {
    Some(connection) if draws.double() < connection.probability =>
      match connection.kind {
        Close => Some(Close)
        Partial => Some(Partial)
      }
    _ => None
  }
  (delay_ms, connection)
}

///|
/// A delay drawn from `distribution`, in whole milliseconds.
fn sample(distribution : @definitions.Distribution, g : @prng.Generator) -> Int {
  match distribution {
    Fixed(ms) => ms
    Uniform(min~, max~) => {
      // At most 2^31 values, so the bias of the remainder is below 2^-32.
      let count = (max - min).to_uint64() + 1UL
      min + (g.uint64() % count).to_int()
    }
    Lognormal(median~, sigma~) =>
      milliseconds(median.to_double() * @math.exp(sigma * standard_normal(g)))
  }
}

///|
/// A number drawn from the standard normal distribution, by Marsaglia's
/// polar method. It uses only arithmetic, `sqrt` and `ln`, which give the
/// same results on every target, unlike `sin` and `cos`.
fn standard_normal(g : @prng.Generator) -> Double {
  for ;; {
    let u = 2.0 * g.double() - 1.0
    let v = 2.0 * g.double() - 1.0
    let s = u * u + v * v
    if s > 0.0 && s < 1.0 {
      return u * (-2.0 * @math.ln(s) / s).sqrt()
    }
  }
}

///|
/// `ms` rounded to whole milliseconds, from 0 to the longest delay a
/// Definition file can give, 2147483647.
fn milliseconds(ms : Double) -> Int {
  if ms.is_nan() || ms <= 0.0 {
    // NaN comes only from a median of 0 times an infinite factor.
    0
  } else if ms >= 2147483647.0 {
    2147483647
  } else {
    ms.round().to_int()
  }
}
