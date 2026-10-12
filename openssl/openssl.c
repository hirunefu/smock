// smock's bindings to OpenSSL (ADR 0001). They call OpenSSL only: no
// sockets, no files. Each TLS connection reads from and writes to two memory
// BIOs, and the MoonBit side carries the bytes between them and the network.
//
// Contexts and connections are MoonBit external objects: their finalizers
// free the OpenSSL objects when MoonBit drops the last reference.

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <moonbit.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

// ---------------------------------------------------------------------------
// Errors

// The reason of the earliest error on OpenSSL's error queue, such as
// "certificate verify failed", then clears the queue. Empty when the queue is
// empty.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_take_error(void) {
  unsigned long code = ERR_get_error();
  ERR_clear_error();
  const char *reason = code == 0 ? NULL : ERR_reason_error_string(code);
  char fallback[32];
  if (code != 0 && reason == NULL) {
    snprintf(fallback, sizeof fallback, "error %d", ERR_GET_REASON(code));
    reason = fallback;
  }
  int32_t length = reason == NULL ? 0 : (int32_t)strlen(reason);
  moonbit_bytes_t out = moonbit_make_bytes(length, 0);
  if (length > 0) {
    memcpy(out, reason, (size_t)length);
  }
  return out;
}

// Whether the most recent error on the queue says that no further PEM block
// of the wanted kind was found. Reading a PEM sequence ends with that error.
static int no_more_pem(void) {
  unsigned long code = ERR_peek_last_error();
  return ERR_GET_LIB(code) == ERR_LIB_PEM &&
         ERR_GET_REASON(code) == PEM_R_NO_START_LINE;
}

// A PEM password callback that refuses: encrypted keys are not supported, and
// OpenSSL must never prompt on the terminal.
static int no_password(char *buf, int size, int rwflag, void *userdata) {
  (void)buf;
  (void)size;
  (void)rwflag;
  (void)userdata;
  return -1;
}

static BIO *pem_bio(moonbit_bytes_t pem) {
  return BIO_new_mem_buf(pem, (int)Moonbit_array_length(pem));
}

// ---------------------------------------------------------------------------
// Contexts

typedef struct {
  SSL_CTX *ctx;
} smock_ctx;

static void smock_ctx_finalize(void *object) {
  smock_ctx *self = object;
  // OpenSSL counts references to a context: connections made from it keep
  // it, and its ALPN list, until they are freed too.
  SSL_CTX_free(self->ctx);
}

// The protocols a server accepts by ALPN, in wire format and in order of
// preference. A context keeps its list in its ex_data, so OpenSSL frees the
// list with the context.
typedef struct {
  unsigned int length;
  unsigned char wire[];
} smock_alpn;

static void smock_alpn_free(void *parent, void *pointer, CRYPTO_EX_DATA *data,
                            int index, long argl, void *argp) {
  (void)parent;
  (void)data;
  (void)index;
  (void)argl;
  (void)argp;
  OPENSSL_free(pointer);
}

// The ex_data index of a context's smock_alpn, or -1 if not registered yet.
static int smock_alpn_index = -1;

// A context for TLS 1.2 and 1.3. `server` is 1 for a server and 0 for a
// client. Its `ctx` is NULL when OpenSSL could not create it.
MOONBIT_FFI_EXPORT smock_ctx *smock_openssl_ctx_new(int32_t server) {
  if (smock_alpn_index < 0) {
    smock_alpn_index =
        SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, smock_alpn_free);
  }
  smock_ctx *self = moonbit_make_external_object(smock_ctx_finalize,
                                                 sizeof(smock_ctx));
  SSL_CTX *ctx = smock_alpn_index < 0
                     ? NULL
                     : SSL_CTX_new(server ? TLS_server_method()
                                          : TLS_client_method());
  self->ctx = ctx;
  if (ctx != NULL) {
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS);
    SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION);
    if (server) {
      // Resumption uses stateless session tickets only, so memory does not
      // grow with the number of clients.
      SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
    } else {
      SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    }
  }
  return self;
}

MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_is_null(smock_ctx *self) {
  return self->ctx == NULL;
}

// Loads a certificate chain in PEM: the leaf first, then the certificates
// that issued it. Returns how many certificates it loaded, 0 when `pem`
// holds no PEM certificate, or -1 when one cannot be used (see
// smock_openssl_take_error).
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_use_chain(smock_ctx *self,
                                                       moonbit_bytes_t pem) {
  ERR_clear_error();
  BIO *bio = pem_bio(pem);
  if (bio == NULL) {
    return -1;
  }
  int32_t count = 0;
  X509 *leaf = PEM_read_bio_X509_AUX(bio, NULL, no_password, NULL);
  if (leaf == NULL) {
    count = no_more_pem() ? 0 : -1;
    if (count == 0) {
      ERR_clear_error();
    }
    BIO_free(bio);
    return count;
  }
  int ok = SSL_CTX_use_certificate(self->ctx, leaf) == 1 &&
           SSL_CTX_clear_chain_certs(self->ctx) == 1;
  X509_free(leaf);
  count = 1;
  while (ok) {
    X509 *issuer = PEM_read_bio_X509(bio, NULL, no_password, NULL);
    if (issuer == NULL) {
      if (no_more_pem()) {
        ERR_clear_error();
      } else {
        ok = 0;
      }
      break;
    }
    // On success the context owns `issuer`.
    if (SSL_CTX_add0_chain_cert(self->ctx, issuer) != 1) {
      X509_free(issuer);
      ok = 0;
      break;
    }
    count++;
  }
  BIO_free(bio);
  return ok ? count : -1;
}

// Loads the private key of the leaf certificate from PEM (PKCS#8, PKCS#1 or
// SEC1). Returns 1, 0 when `pem` holds no PEM private key, -1 when it cannot
// be used, or -2 when it does not belong to the leaf certificate.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_use_key(smock_ctx *self,
                                                     moonbit_bytes_t pem) {
  ERR_clear_error();
  BIO *bio = pem_bio(pem);
  if (bio == NULL) {
    return -1;
  }
  EVP_PKEY *key = PEM_read_bio_PrivateKey(bio, NULL, no_password, NULL);
  BIO_free(bio);
  if (key == NULL) {
    if (no_more_pem()) {
      ERR_clear_error();
      return 0;
    }
    return -1;
  }
  int ok = SSL_CTX_use_PrivateKey(self->ctx, key) == 1;
  EVP_PKEY_free(key);
  if (!ok) {
    // A key of the leaf's type that is not the leaf's own.
    unsigned long code = ERR_peek_last_error();
    if (ERR_GET_LIB(code) == ERR_LIB_X509 &&
        ERR_GET_REASON(code) == X509_R_KEY_VALUES_MISMATCH) {
      ERR_clear_error();
      return -2;
    }
    return -1;
  }
  return 1;
}

// Whether the private key belongs to the leaf certificate: 1 or 0.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_check_key(smock_ctx *self) {
  int ok = SSL_CTX_check_private_key(self->ctx) == 1;
  ERR_clear_error();
  return ok;
}

// Adds every PEM certificate in `pem` to the certificates a client trusts.
// Returns how many it added, or -1 when one cannot be used.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_trust(smock_ctx *self,
                                                   moonbit_bytes_t pem) {
  ERR_clear_error();
  BIO *bio = pem_bio(pem);
  if (bio == NULL) {
    return -1;
  }
  X509_STORE *store = SSL_CTX_get_cert_store(self->ctx);
  int32_t count = 0;
  for (;;) {
    X509 *cert = PEM_read_bio_X509(bio, NULL, no_password, NULL);
    if (cert == NULL) {
      if (no_more_pem()) {
        ERR_clear_error();
      } else {
        count = -1;
      }
      break;
    }
    int ok = X509_STORE_add_cert(store, cert) == 1;
    X509_free(cert);
    if (!ok) {
      count = -1;
      break;
    }
    count++;
  }
  BIO_free(bio);
  return count;
}

// Picks the first protocol in the server's list that the client offers. When
// the client offers ALPN but none of them, the handshake fails with the
// no_application_protocol alert (RFC 7301, section 3.2). A client that sends
// no ALPN never reaches this callback.
static int smock_alpn_select(SSL *ssl, const unsigned char **out,
                             unsigned char *out_length,
                             const unsigned char *offered,
                             unsigned int offered_length, void *arg) {
  (void)arg;
  const smock_alpn *accepted =
      SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), smock_alpn_index);
  unsigned char *selected = NULL;
  if (accepted != NULL &&
      SSL_select_next_proto(&selected, out_length, accepted->wire,
                            accepted->length, offered,
                            offered_length) == OPENSSL_NPN_NEGOTIATED) {
    *out = selected;
    return SSL_TLSEXT_ERR_OK;
  }
  return SSL_TLSEXT_ERR_ALERT_FATAL;
}

// Sets the protocols a server accepts (`server` = 1) or a client offers
// (`server` = 0) by ALPN, in wire format. Returns 1, or 0 on failure.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_set_alpn(smock_ctx *self,
                                                      int32_t server,
                                                      moonbit_bytes_t wire) {
  unsigned int length = (unsigned int)Moonbit_array_length(wire);
  if (!server) {
    // SSL_CTX_set_alpn_protos returns 0 on success.
    return SSL_CTX_set_alpn_protos(self->ctx, wire, length) == 0;
  }
  smock_alpn *accepted = OPENSSL_malloc(sizeof(smock_alpn) + length);
  if (accepted == NULL) {
    return 0;
  }
  accepted->length = length;
  memcpy(accepted->wire, wire, length);
  // A context gets its list once, before it makes any connection.
  if (SSL_CTX_get_ex_data(self->ctx, smock_alpn_index) != NULL ||
      SSL_CTX_set_ex_data(self->ctx, smock_alpn_index, accepted) != 1) {
    OPENSSL_free(accepted);
    return 0;
  }
  SSL_CTX_set_alpn_select_cb(self->ctx, smock_alpn_select, NULL);
  return 1;
}

// ---------------------------------------------------------------------------
// Connections

typedef struct {
  SSL *ssl;
} smock_ssl;

static void smock_ssl_finalize(void *object) {
  smock_ssl *self = object;
  // Frees both memory BIOs too.
  SSL_free(self->ssl);
}

// A connection made from `ctx`, as a server (`server` = 1) or a client. Its
// `ssl` is NULL when OpenSSL could not create it.
MOONBIT_FFI_EXPORT smock_ssl *smock_openssl_ssl_new(smock_ctx *ctx,
                                                    int32_t server) {
  smock_ssl *self = moonbit_make_external_object(smock_ssl_finalize,
                                                 sizeof(smock_ssl));
  self->ssl = NULL;
  SSL *ssl = SSL_new(ctx->ctx);
  BIO *input = BIO_new(BIO_s_mem());
  BIO *output = BIO_new(BIO_s_mem());
  if (ssl == NULL || input == NULL || output == NULL) {
    SSL_free(ssl);
    BIO_free(input);
    BIO_free(output);
    ERR_clear_error();
    return self;
  }
  // An empty input BIO asks for more input instead of reporting an EOF.
  BIO_set_mem_eof_return(input, -1);
  SSL_set_bio(ssl, input, output);
  if (server) {
    SSL_set_accept_state(ssl);
  } else {
    SSL_set_connect_state(ssl);
  }
  self->ssl = ssl;
  return self;
}

MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_is_null(smock_ssl *self) {
  return self->ssl == NULL;
}

// Sets the name a client sends by SNI and checks the server's certificate
// against. Returns 1, or 0 on failure.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_set_server_name(
    smock_ssl *self, moonbit_bytes_t name) {
  char *copy = OPENSSL_strndup((const char *)name, Moonbit_array_length(name));
  if (copy == NULL) {
    return 0;
  }
  int ok = SSL_set_tlsext_host_name(self->ssl, copy) == 1 &&
           SSL_set1_host(self->ssl, copy) == 1;
  OPENSSL_free(copy);
  return ok;
}

// Hands `length` bytes from the peer, from `offset` in `data`, to the
// connection. Returns how many it took (all of them), or -1.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_receive(smock_ssl *self,
                                                     moonbit_bytes_t data,
                                                     int32_t offset,
                                                     int32_t length) {
  if (length == 0) {
    return 0;
  }
  return BIO_write(SSL_get_rbio(self->ssl), data + offset, length);
}

// Takes every byte the connection has written for the peer.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_ssl_take_output(
    smock_ssl *self) {
  BIO *output = SSL_get_wbio(self->ssl);
  size_t pending = BIO_ctrl_pending(output);
  int32_t length = pending > INT_MAX ? INT_MAX : (int32_t)pending;
  moonbit_bytes_t out = moonbit_make_bytes(length, 0);
  if (length > 0 && BIO_read(output, out, length) != length) {
    // A memory BIO hands out everything it holds; this does not happen.
    abort();
  }
  return out;
}

// What an SSL call's result means for the caller:
//   >= 0  the call's own result
//   -1    it needs more input from the peer
//   -2    the peer closed the TLS connection (close_notify)
//   -3    it failed (see smock_openssl_take_error)
static int32_t smock_result(SSL *ssl, int result) {
  if (result > 0) {
    return result;
  }
  switch (SSL_get_error(ssl, result)) {
  case SSL_ERROR_WANT_READ:
    return -1;
  case SSL_ERROR_ZERO_RETURN:
    return -2;
  default:
    return -3;
  }
}

// Advances the handshake: 1 when it is done, or see smock_result.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_handshake(smock_ssl *self) {
  ERR_clear_error();
  return smock_result(self->ssl, SSL_do_handshake(self->ssl));
}

// Reads up to `length` bytes of plaintext into `buf` at `offset`: how many,
// or see smock_result.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_read(smock_ssl *self,
                                                  moonbit_bytes_t buf,
                                                  int32_t offset,
                                                  int32_t length) {
  ERR_clear_error();
  return smock_result(self->ssl, SSL_read(self->ssl, buf + offset, length));
}

// Encrypts `length` bytes of `data` from `offset` for the peer: how many
// (all of them, since the output BIO grows), or see smock_result.
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_write(smock_ssl *self,
                                                   moonbit_bytes_t data,
                                                   int32_t offset,
                                                   int32_t length) {
  if (length == 0) {
    return 0;
  }
  ERR_clear_error();
  return smock_result(self->ssl, SSL_write(self->ssl, data + offset, length));
}

// Writes a close_notify alert for the peer, once.
MOONBIT_FFI_EXPORT void smock_openssl_ssl_shutdown(smock_ssl *self) {
  if ((SSL_get_shutdown(self->ssl) & SSL_SENT_SHUTDOWN) == 0 &&
      SSL_is_init_finished(self->ssl)) {
    SSL_shutdown(self->ssl);
  }
  ERR_clear_error();
}

// The protocol ALPN selected, or empty when none was.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_ssl_alpn(smock_ssl *self) {
  const unsigned char *protocol = NULL;
  unsigned int length = 0;
  SSL_get0_alpn_selected(self->ssl, &protocol, &length);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(out, protocol, length);
  }
  return out;
}
