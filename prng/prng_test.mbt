// The generator's outputs are pinned: a seed must give the same sequence on
// every target and in every release, or a seeded Fault stops replaying.
// The expected values come from a separate implementation of SplitMix64 and
// xoshiro256** written from the published algorithms.

///|
test "a seed gives a fixed sequence of 64-bit outputs" {
  let first = (seed : UInt64) => {
    let g = @prng.Generator(seed)
    [g.uint64(), g.uint64(), g.uint64(), g.uint64()]
  }
  inspect(
    [0UL, 42, 9007199254740991]
    .map(seed => "\{seed}: \{first(seed).map(n => n.to_string()).join(" ")}")
    .join("\n"),
    content=(
      #|0: 11091344671253066420 13793997310169335082 1900383378846508768 7684712102626143532
      #|42: 1546998764402558742 6990951692964543102 12544586762248559009 17057574109182124193
      #|9007199254740991: 4096853559096369217 15791922985970664313 1971179688699188416 13574082168775316473
    ),
  )
}

///|
test "a double is the top 53 bits of an output, scaled into [0, 1)" {
  let g = @prng.Generator(42)
  inspect(
    [g.double(), g.double(), g.double()].map(d => d.to_string()).join(" "),
    content="0.08386297105988216 0.3789802506626686 0.6800434110281394",
  )
}

///|
test "split advances the generator once and seeds a new one from that output" {
  let parent = @prng.Generator(42)
  let child = parent.split()
  inspect(
    "child: \{child.uint64()} \{child.uint64()}\nparent: \{parent.uint64()}",
    content=(
      #|child: 10296431413203944531 1184342940732292706
      #|parent: 6990951692964543102
    ),
  )
}

///|
test "below draws uniformly below a count, drawing again for the outputs that would favour low values" {
  // Seed 42 outputs 1546998764402558742, 6990951692964543102,
  // 12544586762248559009, then 17057574109182124193 (the test above).
  let g = @prng.Generator(42)
  inspect(g.below(10UL), content="2")
  // For 2^63 + 1, the outputs below 2^64 mod (2^63 + 1) = 2^63 - 1 are
  // drawn again: the next two are, and the third gives
  // 12544586762248559009 - (2^63 + 1).
  let g = @prng.Generator(42)
  inspect(
    "\{g.below(9223372036854775809UL)} then \{g.uint64()}",
    content="3321214725393783200 then 17057574109182124193",
  )
  inspect(@prng.Generator(42).below(1UL), content="0")
  // At the bound itself. For 2^63 + 1, the outputs kept are those from
  // 2^63 - 1 up: 2^63 + 1 of them, one for each value, which is what makes
  // every value equally likely. 2^63 - 1 is the only output that gives the
  // value 2^63 - 1, so it is kept, and 2^63 - 2, just below the bound, is
  // drawn again. Seed 5527295704097554033's first output is 2^63 - 1, and
  // seed 11534342769042786949's is 2^63 - 2, then 17842481637524831588:
  // found, and checked, with a separate implementation of SplitMix64 and
  // xoshiro256** written from the published algorithms, by inverting their
  // output functions.
  let kept = @prng.Generator(5527295704097554033UL)
  let redrawn = @prng.Generator(11534342769042786949UL)
  inspect(
    "\{kept.uint64()} \{redrawn.uint64()} then \{redrawn.uint64()}",
    content="9223372036854775807 9223372036854775806 then 17842481637524831588",
  )
  inspect(
    @prng.Generator(5527295704097554033UL).below(9223372036854775809UL),
    content="9223372036854775807",
  )
  // 17842481637524831588 - (2^63 + 1).
  inspect(
    @prng.Generator(11534342769042786949UL).below(9223372036854775809UL),
    content="8619109600670055779",
  )
}
