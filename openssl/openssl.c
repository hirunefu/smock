// smock's bindings to OpenSSL (ADR 0001). They call OpenSSL only: no
// sockets, no files. Each TLS connection reads from and writes to two memory
// BIOs, and the MoonBit side carries the bytes between them and the network.
// Self-signed certificates are generated in memory too.
//
// Contexts and connections are MoonBit external objects: their finalizers
// free the OpenSSL objects when MoonBit drops the last reference.

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <moonbit.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
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
// preference: `length` octets, then the same list without h2 in
// `without_h2` octets, for a connection whose suite HTTP/2 prohibits
// (smock_suite_allows_h2). A context keeps its lists in its ex_data, so
// OpenSSL frees them with the context.
typedef struct {
  unsigned int length;
  unsigned int without_h2;
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

// The ex_data index where a client connection keeps the last alert its peer
// sent, or -1 if not registered yet.
static int smock_alert_index = -1;

// The info callback of client connections: keeps the last alert the peer
// sent as OpenSSL passes it, its level in the high octet and its
// description in the low one, so never 0 (smock_openssl_ssl_alert).
static void smock_keep_alert(const SSL *ssl, int where, int value) {
  if ((where & SSL_CB_READ_ALERT) == SSL_CB_READ_ALERT &&
      smock_alert_index >= 0) {
    SSL_set_ex_data((SSL *)ssl, smock_alert_index, (void *)(intptr_t)value);
  }
}

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
      // A client keeps the last alert its peer sent; a server keeps none.
      if (smock_alert_index < 0) {
        smock_alert_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
      }
      SSL_CTX_set_info_callback(ctx, smock_keep_alert);
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
// Returns how many it added, or -1 when one cannot be used. Client side:
// only the bindings' tests use it (see client.mbt).
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

// Caps a client at TLS 1.2 and has it offer only the suites of `ciphers`, an
// OpenSSL cipher list such as "ECDHE-RSA-AES128-GCM-SHA256". Returns 1, or 0
// on failure (see smock_openssl_take_error). Client side: only the bindings'
// tests use it, to choose the TLS 1.2 suite (see client.mbt).
MOONBIT_FFI_EXPORT int32_t smock_openssl_ctx_tls12_ciphers(
    smock_ctx *self, moonbit_bytes_t ciphers) {
  ERR_clear_error();
  char *copy =
      OPENSSL_strndup((const char *)ciphers, Moonbit_array_length(ciphers));
  if (copy == NULL) {
    return 0;
  }
  int ok = SSL_CTX_set_max_proto_version(self->ctx, TLS1_2_VERSION) == 1 &&
           SSL_CTX_set_cipher_list(self->ctx, copy) == 1;
  OPENSSL_free(copy);
  return ok;
}

// Whether HTTP/2 may run over the suite the connection uses (RFC 9113,
// section 9.2.2). Over TLS 1.3 every suite will do. Over TLS 1.2, Appendix A
// of RFC 9113 prohibits every suite without an ephemeral key exchange or
// without an AEAD cipher, so only ECDHE or DHE, with or without a PSK, with
// an AEAD cipher will do. For TLS 1.2, OpenSSL has chosen the suite by the
// time it calls the ALPN callback.
static int smock_suite_allows_h2(const SSL *ssl) {
  if (SSL_version(ssl) >= TLS1_3_VERSION) {
    return 1;
  }
  const SSL_CIPHER *suite = SSL_get_pending_cipher(ssl);
  if (suite == NULL || !SSL_CIPHER_is_aead(suite)) {
    return 0;
  }
  switch (SSL_CIPHER_get_kx_nid(suite)) {
  case NID_kx_ecdhe:
  case NID_kx_dhe:
  case NID_kx_ecdhe_psk:
  case NID_kx_dhe_psk:
    return 1;
  default:
    return 0;
  }
}

// Picks the first protocol in the server's list that the client offers,
// skipping h2 over a TLS 1.2 suite that HTTP/2 prohibits, so that a client
// that also offers http/1.1 gets it rather than a connection it would have
// to fail (RFC 9113, section 9.2.2). When the client offers ALPN but none of
// them, the handshake fails with the no_application_protocol alert (RFC
// 7301, section 3.2). A client that sends no ALPN never reaches this
// callback.
static int smock_alpn_select(SSL *ssl, const unsigned char **out,
                             unsigned char *out_length,
                             const unsigned char *offered,
                             unsigned int offered_length, void *arg) {
  (void)arg;
  const smock_alpn *accepted =
      SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), smock_alpn_index);
  if (accepted == NULL) {
    return SSL_TLSEXT_ERR_ALERT_FATAL;
  }
  const unsigned char *list = accepted->wire;
  unsigned int length = accepted->length;
  // The suite is checked only when the list holds h2.
  if (accepted->without_h2 != length && !smock_suite_allows_h2(ssl)) {
    list += length;
    length = accepted->without_h2;
  }
  unsigned char *selected = NULL;
  if (length > 0 &&
      SSL_select_next_proto(&selected, out_length, list, length, offered,
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
  smock_alpn *accepted =
      OPENSSL_malloc(sizeof(smock_alpn) + 2 * (size_t)length);
  if (accepted == NULL) {
    return 0;
  }
  accepted->length = length;
  memcpy(accepted->wire, wire, length);
  // The list without h2 follows it.
  unsigned int kept = 0;
  for (unsigned int i = 0; i < length;) {
    unsigned int size = 1u + wire[i];
    if (size > length - i) {
      OPENSSL_free(accepted);
      return 0;
    }
    if (!(wire[i] == 2 && memcmp(wire + i + 1, "h2", 2) == 0)) {
      memcpy(accepted->wire + length + kept, wire + i, size);
      kept += size;
    }
    i += size;
  }
  accepted->without_h2 = kept;
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
// against. Returns 1, or 0 on failure. Client side: only the bindings' tests
// use it (see client.mbt).
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

// Updates the keys this side sends with and asks the peer to update its own
// (TLS 1.3), and writes the KeyUpdate message at once. Returns 1, or 0 on
// failure (see smock_openssl_take_error). Only the e2e tests and the
// bindings' tests ask (see client.mbt).
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_update_keys(smock_ssl *self) {
  ERR_clear_error();
  return SSL_key_update(self->ssl, SSL_KEY_UPDATE_REQUESTED) == 1 &&
         SSL_do_handshake(self->ssl) == 1;
}

// The protocol ALPN selected, or empty when none was. smock's server asks it
// of each connection of its TLS port, and the e2e tests and the bindings'
// tests of their clients (see client.mbt).
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

// The description of the last alert the peer of a client connection sent,
// such as 120 for no_application_protocol (RFC 8446, section 6), or -1 when
// it sent none. Only the e2e tests and the bindings' tests ask (see
// client.mbt).
MOONBIT_FFI_EXPORT int32_t smock_openssl_ssl_alert(smock_ssl *self) {
  if (smock_alert_index < 0) {
    return -1;
  }
  intptr_t value = (intptr_t)SSL_get_ex_data(self->ssl, smock_alert_index);
  return value == 0 ? -1 : (int32_t)(value & 0xff);
}

// ---------------------------------------------------------------------------
// Self-signed certificates

// A certificate and its private key, generated in memory.
typedef struct {
  X509 *cert;
  EVP_PKEY *key;
} smock_self_signed;

static void smock_self_signed_finalize(void *object) {
  smock_self_signed *self = object;
  X509_free(self->cert);
  EVP_PKEY_free(self->key);
}

// Adds `name` to `names`: as an IP address when OpenSSL reads it as an IPv4
// or IPv6 address, otherwise as a DNS name. Returns 1, or 0 on failure.
static int add_name(GENERAL_NAMES *names, const char *name) {
  GENERAL_NAME *entry = GENERAL_NAME_new();
  if (entry == NULL) {
    return 0;
  }
  ASN1_OCTET_STRING *ip = a2i_IPADDRESS(name);
  if (ip != NULL) {
    GENERAL_NAME_set0_value(entry, GEN_IPADD, ip);
  } else {
    ASN1_IA5STRING *dns = ASN1_IA5STRING_new();
    if (dns == NULL || ASN1_STRING_set(dns, name, (int)strlen(name)) != 1) {
      ASN1_IA5STRING_free(dns);
      GENERAL_NAME_free(entry);
      return 0;
    }
    GENERAL_NAME_set0_value(entry, GEN_DNS, dns);
  }
  if (sk_GENERAL_NAME_push(names, entry) <= 0) {
    GENERAL_NAME_free(entry);
    return 0;
  }
  return 1;
}

// Adds the extension `nid` with the value `value`, in the syntax of
// OpenSSL's configuration files, to `cert`. Returns 1, or 0 on failure.
static int add_extension(X509 *cert, int nid, const char *value) {
  X509V3_CTX ctx;
  X509V3_set_ctx(&ctx, cert, cert, NULL, NULL, 0);
  X509_EXTENSION *extension = X509V3_EXT_conf_nid(NULL, &ctx, nid, value);
  if (extension == NULL) {
    return 0;
  }
  int ok = X509_add_ext(cert, extension, -1) == 1;
  X509_EXTENSION_free(extension);
  return ok;
}

// Generates a new ECDSA P-256 key and a certificate for it that it signs
// itself, for a TLS server, valid from an hour ago (for clocks that are a
// little behind) for `days` days. Its subject alternative names are
// `names`: each name followed by a NUL byte. Its serial number is 127
// random bits, so no two certificates share one. Its `cert` is NULL when
// OpenSSL could not create it (see smock_openssl_take_error).
MOONBIT_FFI_EXPORT smock_self_signed *smock_openssl_self_signed_new(
    moonbit_bytes_t names, int32_t days) {
  ERR_clear_error();
  smock_self_signed *self = moonbit_make_external_object(
      smock_self_signed_finalize, sizeof(smock_self_signed));
  self->cert = NULL;
  self->key = NULL;
  EVP_PKEY *key = EVP_EC_gen("P-256");
  X509 *cert = X509_new();
  GENERAL_NAMES *sans = sk_GENERAL_NAME_new_null();
  BIGNUM *serial = BN_new();
  int ok = key != NULL && cert != NULL && sans != NULL && serial != NULL &&
           X509_set_version(cert, X509_VERSION_3) == 1 &&
           BN_rand(serial, 127, BN_RAND_TOP_ANY, BN_RAND_BOTTOM_ANY) == 1 &&
           BN_to_ASN1_INTEGER(serial, X509_get_serialNumber(cert)) != NULL &&
           X509_gmtime_adj(X509_getm_notBefore(cert), -3600) != NULL &&
           X509_time_adj_ex(X509_getm_notAfter(cert), days, 0, NULL) != NULL;
  X509_NAME *subject = ok ? X509_get_subject_name(cert) : NULL;
  ok = ok &&
       X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
                                  (const unsigned char *)"smock self-signed",
                                  -1, -1, 0) == 1 &&
       X509_set_issuer_name(cert, subject) == 1 &&
       X509_set_pubkey(cert, key) == 1;
  const char *name = (const char *)names;
  const char *end = name + Moonbit_array_length(names);
  while (ok && name < end) {
    const char *nul = memchr(name, 0, (size_t)(end - name));
    ok = nul != NULL && add_name(sans, name);
    name = ok ? nul + 1 : end;
  }
  ok = ok && sk_GENERAL_NAME_num(sans) > 0 &&
       X509_add1_ext_i2d(cert, NID_subject_alt_name, sans, 0,
                         X509V3_ADD_DEFAULT) == 1 &&
       add_extension(cert, NID_basic_constraints, "critical,CA:FALSE") &&
       add_extension(cert, NID_ext_key_usage, "serverAuth") &&
       add_extension(cert, NID_subject_key_identifier, "hash") &&
       X509_sign(cert, key, EVP_sha256()) > 0;
  GENERAL_NAMES_free(sans);
  BN_free(serial);
  if (!ok) {
    X509_free(cert);
    EVP_PKEY_free(key);
    return self;
  }
  self->cert = cert;
  self->key = key;
  return self;
}

MOONBIT_FFI_EXPORT int32_t smock_openssl_self_signed_is_null(
    smock_self_signed *self) {
  return self->cert == NULL;
}

// The bytes `bio` holds, then frees it. Empty when `bio` is NULL.
static moonbit_bytes_t take_bio(BIO *bio) {
  char *data = NULL;
  long length = bio == NULL ? 0 : BIO_get_mem_data(bio, &data);
  if (length < 0 || length > INT_MAX) {
    length = 0;
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(out, data, (size_t)length);
  }
  BIO_free(bio);
  return out;
}

// The certificate in PEM, or empty on failure.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_self_signed_certificate(
    smock_self_signed *self) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (bio != NULL && PEM_write_bio_X509(bio, self->cert) != 1) {
    BIO_free(bio);
    bio = NULL;
  }
  return take_bio(bio);
}

// The private key in PEM (PKCS#8, not encrypted), or empty on failure.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_self_signed_private_key(
    smock_self_signed *self) {
  BIO *bio = BIO_new(BIO_s_mem());
  if (bio != NULL && PEM_write_bio_PrivateKey(bio, self->key, NULL, NULL, 0,
                                              NULL, NULL) != 1) {
    BIO_free(bio);
    bio = NULL;
  }
  return take_bio(bio);
}

// The SHA-256 digest of the certificate's DER encoding: 32 bytes, or empty
// on failure.
MOONBIT_FFI_EXPORT moonbit_bytes_t smock_openssl_self_signed_sha256(
    smock_self_signed *self) {
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int length = 0;
  if (X509_digest(self->cert, EVP_sha256(), digest, &length) != 1) {
    length = 0;
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)length, 0);
  if (length > 0) {
    memcpy(out, digest, length);
  }
  return out;
}
