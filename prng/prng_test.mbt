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
