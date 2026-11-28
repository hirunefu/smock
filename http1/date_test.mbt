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
  // The edges of the calendar and of the clock, each from GNU date
  // (`date -u -d @<seconds> '+%a, %d %b %Y %H:%M:%S GMT'`): the last
  // millisecond before the epoch; the end of February and the start of March
  // in 1900, a century year that is no leap year, and the last second of the
  // leap day of 2000, a year divisible by 400 (the Gregorian calendar, which
  // GNU date extends backward); the last second of each month of a leap
  // year, which gives every weekday and every month (RFC 9110, section
  // 5.6.7: day-name and month); and the first and last second of an hour.
  let edges = [
    -1L, -2203891201000L, -2203891200000L, 951868799000L, 1706745599000L, 1709251199000L,
    1711929599000L, 1714521599000L, 1717199999000L, 1719791999000L, 1722470399000L,
    1725148799000L, 1727740799000L, 1730419199000L, 1733011199000L, 1735689599000L,
    1792630799000L, 1792630800000L, 1792709999000L, 1792710000000L,
  ]
  inspect(
    edges.map(ms => dates.at(ms)).join("\n"),
    content=(
      #|Wed, 31 Dec 1969 23:59:59 GMT
      #|Wed, 28 Feb 1900 23:59:59 GMT
      #|Thu, 01 Mar 1900 00:00:00 GMT
      #|Tue, 29 Feb 2000 23:59:59 GMT
      #|Wed, 31 Jan 2024 23:59:59 GMT
      #|Thu, 29 Feb 2024 23:59:59 GMT
      #|Sun, 31 Mar 2024 23:59:59 GMT
      #|Tue, 30 Apr 2024 23:59:59 GMT
      #|Fri, 31 May 2024 23:59:59 GMT
      #|Sun, 30 Jun 2024 23:59:59 GMT
      #|Wed, 31 Jul 2024 23:59:59 GMT
      #|Sat, 31 Aug 2024 23:59:59 GMT
      #|Mon, 30 Sep 2024 23:59:59 GMT
      #|Thu, 31 Oct 2024 23:59:59 GMT
      #|Sat, 30 Nov 2024 23:59:59 GMT
      #|Tue, 31 Dec 2024 23:59:59 GMT
      #|Thu, 22 Oct 2026 00:59:59 GMT
      #|Thu, 22 Oct 2026 01:00:00 GMT
      #|Thu, 22 Oct 2026 22:59:59 GMT
      #|Thu, 22 Oct 2026 23:00:00 GMT
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
  // The first call of a new cache's `at` gives the value of its own second
  // (DateCache::DateCache): the first second of the epoch, and the one
  // after it too (GNU date).
  inspect(
    [
      @http1.DateCache().at(0L),
      @http1.DateCache().at(999L),
      @http1.DateCache().at(1000L),
    ].join("\n"),
    content=(
      #|Thu, 01 Jan 1970 00:00:00 GMT
      #|Thu, 01 Jan 1970 00:00:00 GMT
      #|Thu, 01 Jan 1970 00:00:01 GMT
    ),
  )
}
