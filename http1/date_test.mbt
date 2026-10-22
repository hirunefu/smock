// The value of the Date field, through the module's public interface. The
// expected values come from GNU date and from RFC 9110's own example.

///|
test "the Date value is the time in IMF-fixdate form: weekday, zero-padded day, month, four-digit year, time, and GMT" {
  let dates = @http1.DateCache()
  let instants = [
    1792679830000L, 784111777000L, 0L, 978307200000L, 1709197507000L, 946684799999L,
    951868800000L,
  ]
  inspect(
    instants.map(ms => dates.at(ms)).join("\n"),
    content=(
      #|Thu, 22 Oct 2026 14:37:10 GMT
      #|Sun, 06 Nov 1994 08:49:37 GMT
      #|Thu, 01 Jan 1970 00:00:00 GMT
      #|Mon, 01 Jan 2001 00:00:00 GMT
      #|Thu, 29 Feb 2024 09:05:07 GMT
      #|Fri, 31 Dec 1999 23:59:59 GMT
      #|Wed, 01 Mar 2000 00:00:00 GMT
    ),
  )
}

///|
test "the Date value is formatted once per second: within a second the same value comes back, and the next second gets its own" {
  let dates = @http1.DateCache()
  let first = dates.at(1792679830000L)
  let later = dates.at(1792679830999L)
  inspect(physical_equal(first, later), content="true")
  inspect(dates.at(1792679831000L), content="Thu, 22 Oct 2026 14:37:11 GMT")
  // A clock set back gets the value of its own second.
  inspect(dates.at(1792679830500L), content="Thu, 22 Oct 2026 14:37:10 GMT")
}
