// The Data buckets templates may read, as `data.NAME`. The caller names
// the buckets of the Stub's Mock when templates are parsed, and gives each
// rendering their values: the template package keeps no data.

///|
/// The Data buckets templates may read as `data.NAME`: the names of the
/// buckets of the Stub's Mock. A template that reads any other name does
/// not parse.
pub struct Buckets {
  priv names : Set[String]
}

///|
/// The buckets named `names`. With none, templates read no bucket.
pub fn Buckets::Buckets(names : Array[String]) -> Buckets {
  { names: Set::from_array(names), }
}

///|
/// No buckets: what templates read for a Mock that declares none.
pub let no_buckets : Buckets = Buckets([])
