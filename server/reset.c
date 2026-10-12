// The one C function of the native server, the exception ADR 0001 makes
// for the reset connection Fault (decided in issue #3): moonbitlang/async
// cannot set SO_LINGER, which makes closing a TCP connection send an RST
// instead of a FIN. Any other C needs a new ADR.

#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>

#include <moonbit.h>

// Sets SO_LINGER with a zero timeout on the socket `fd`, so that closing it
// discards anything unsent and resets the connection with an RST. Returns 0,
// or the errno of the failure.
MOONBIT_FFI_EXPORT int32_t smock_reset_on_close(int32_t fd) {
  struct linger linger = {.l_onoff = 1, .l_linger = 0};
  if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof linger) != 0) {
    return errno;
  }
  return 0;
}
