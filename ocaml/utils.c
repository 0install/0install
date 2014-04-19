/* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 */

#define CAML_NAME_SPACE

#include <string.h>
#include <assert.h>

#ifdef DLOPEN_CRYPTO
#include <dlfcn.h>
#endif

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <openssl/ssl.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>

#include <sys/types.h>
#ifndef _WIN32
#include <utime.h>
#else
#include <sys/utime.h>
#endif

#include <errno.h>

#ifndef _WIN32
#include <sys/utsname.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <unistd.h>
#endif

#ifdef WIN32
#include <stdint.h>
#include <windows.h>
#else
#include <pthread.h>
#endif

#define Ctx_val(v) (*((EVP_MD_CTX**)Data_custom_val(v)))

#ifdef DLOPEN_CRYPTO
static EVP_MD_CTX *(*p_EVP_MD_CTX_create)(void);
static int (*p_EVP_DigestInit_ex)(EVP_MD_CTX *, const EVP_MD *, ENGINE *);
static const EVP_MD *(*p_EVP_sha1)(void);
static const EVP_MD *(*p_EVP_sha256)(void);
static int (*p_EVP_DigestUpdate)(EVP_MD_CTX *, const void *, size_t);
static int (*p_EVP_DigestFinal_ex)(EVP_MD_CTX *, unsigned char *, unsigned int *);
static void (*p_EVP_MD_CTX_destroy)(EVP_MD_CTX *);

static int (*p_SSL_library_init)(void);
static void (*p_SSL_load_error_strings)(void);
static int (*p_CRYPTO_num_locks)(void);

static void (*p_CRYPTO_set_locking_callback)(void locking_function(int, int, const char *, int));
static void (*p_CRYPTO_set_id_callback)(unsigned long (*id_function)(void));
static void (*p_CRYPTO_set_dynlock_create_callback)(struct CRYPTO_dynlock_value *(*dyn_create_function)(const char *, int));
static void (*p_CRYPTO_set_dynlock_lock_callback)(void (*dyn_lock_function)(int, struct CRYPTO_dynlock_value *, const char *, int));
static void (*p_CRYPTO_set_dynlock_destroy_callback)(void (*dyn_destroy_function)(struct CRYPTO_dynlock_value *, const char *, int));

void *lookup(void *lib, const char *symbol) {
  void *retval = NULL;
  if (lib != NULL) {
    retval = dlsym(lib, symbol);
  }
  if (retval == NULL) {
    fprintf(stderr, "Warning: symbol %s not found; 0install may crash\n", symbol);
  }
  return retval;
}
#else
#  define p_EVP_MD_CTX_create EVP_MD_CTX_create
#  define p_EVP_DigestInit_ex EVP_DigestInit_ex
#  define p_EVP_sha1 EVP_sha1
#  define p_EVP_sha256 EVP_sha256
#  define p_EVP_DigestUpdate EVP_DigestUpdate
#  define p_EVP_DigestFinal_ex EVP_DigestFinal_ex
#  define p_EVP_MD_CTX_destroy EVP_MD_CTX_destroy

#  define p_SSL_library_init SSL_library_init
#  define p_SSL_load_error_strings SSL_load_error_strings
#  define p_CRYPTO_num_locks CRYPTO_num_locks

#  define p_CRYPTO_set_locking_callback CRYPTO_set_locking_callback
#  define p_CRYPTO_set_id_callback CRYPTO_set_id_callback
#  define p_CRYPTO_set_dynlock_create_callback CRYPTO_set_dynlock_create_callback
#  define p_CRYPTO_set_dynlock_lock_callback CRYPTO_set_dynlock_lock_callback
#  define p_CRYPTO_set_dynlock_destroy_callback CRYPTO_set_dynlock_destroy_callback
#endif

CAMLprim value ocaml_init_zi_crypto(value v_unit) {
#ifdef DLOPEN_CRYPTO
  void *libcrypto;
  void *libssl;

  libcrypto = dlopen("libcrypto.so.1.0.0", RTLD_LAZY | RTLD_GLOBAL);
  if (libcrypto) {
    /* Standard Linux */
    libssl = dlopen("libssl.so.1.0.0", RTLD_LAZY | RTLD_GLOBAL);
  } else {
    /* Fedora */
    libcrypto = dlopen("libcrypto.so.10", RTLD_LAZY | RTLD_GLOBAL);
    libssl = dlopen("libssl.so.10", RTLD_LAZY | RTLD_GLOBAL);
  }

  if (libcrypto == NULL) {
    fprintf(stderr, "Warning: libcrypto not found; 0install will not work fully\n");
  } else {
    p_EVP_MD_CTX_create = dlsym(libcrypto, "EVP_MD_CTX_create");
    p_EVP_DigestInit_ex = dlsym(libcrypto, "EVP_DigestInit_ex");
    p_EVP_sha1 = dlsym(libcrypto, "EVP_sha1");
    p_EVP_sha256 = dlsym(libcrypto, "EVP_sha256");
    p_EVP_DigestUpdate = dlsym(libcrypto, "EVP_DigestUpdate");
    p_EVP_DigestFinal_ex = dlsym(libcrypto, "EVP_DigestFinal_ex");
    p_EVP_MD_CTX_destroy = dlsym(libcrypto, "EVP_MD_CTX_destroy");
  }

  if (libssl == NULL) {
    fprintf(stderr, "Warning: libssl not found; 0install will not work fully\n");
  } else {
    p_SSL_library_init = dlsym(libssl, "SSL_library_init");
    p_SSL_load_error_strings = dlsym(libssl, "SSL_load_error_strings");
    p_CRYPTO_num_locks = dlsym(libssl, "CRYPTO_num_locks");

    p_CRYPTO_set_locking_callback = dlsym(libssl, "CRYPTO_set_locking_callback");
    p_CRYPTO_set_id_callback = dlsym(libssl, "CRYPTO_set_id_callback");
    p_CRYPTO_set_dynlock_create_callback = dlsym(libssl, "CRYPTO_set_dynlock_create_callback");
    p_CRYPTO_set_dynlock_lock_callback = dlsym(libssl, "CRYPTO_set_dynlock_lock_callback");
    p_CRYPTO_set_dynlock_destroy_callback = dlsym(libssl, "CRYPTO_set_dynlock_destroy_callback");
  }
#endif
  return Val_unit;
}

/* SSL threading support.
 * From https://github.com/savonet/ocaml-ssl/blob/master/src/ssl_stubs.c (LGPL 2.1+).
 * Copyright (c) 2003-2005 the Savonet Team. */
#ifdef WIN32
struct CRYPTO_dynlock_value
{
  HANDLE mutex;
};

static HANDLE *mutex_buf = NULL;

static void locking_function(int mode, int n, const char *file, int line)
{
  if (mode & CRYPTO_LOCK)
    WaitForSingleObject(mutex_buf[n], INFINITE);
  else
    ReleaseMutex(mutex_buf[n]);
}

static struct CRYPTO_dynlock_value *dyn_create_function(const char *file, int line)
{
  struct CRYPTO_dynlock_value *value;

  value = malloc(sizeof(struct CRYPTO_dynlock_value));
  if (!value)
    return NULL;
  if (!(value->mutex = CreateMutex(NULL, FALSE, NULL)))
    {
      free(value);
      return NULL;
    }

  return value;
}

static void dyn_lock_function(int mode, struct CRYPTO_dynlock_value *l, const char *file, int line)
{
  if (mode & CRYPTO_LOCK)
    WaitForSingleObject(l->mutex, INFINITE);
  else
    ReleaseMutex(l->mutex);
}

static void dyn_destroy_function(struct CRYPTO_dynlock_value *l, const char *file, int line)
{
  CloseHandle(l->mutex);
  free(l);
}
#else
struct CRYPTO_dynlock_value
{
  pthread_mutex_t mutex;
};

static pthread_mutex_t *mutex_buf = NULL;

static void locking_function(int mode, int n, const char *file, int line)
{
  if (mode & CRYPTO_LOCK)
    pthread_mutex_lock(&mutex_buf[n]);
  else
    pthread_mutex_unlock(&mutex_buf[n]);
}

static unsigned long id_function(void)
{
  return ((unsigned long) pthread_self());
}

static struct CRYPTO_dynlock_value *dyn_create_function(const char *file, int line)
{
  struct CRYPTO_dynlock_value *value;

  value = malloc(sizeof(struct CRYPTO_dynlock_value));
  if (!value)
    return NULL;
  pthread_mutex_init(&value->mutex, NULL);

  return value;
}

static void dyn_lock_function(int mode, struct CRYPTO_dynlock_value *l, const char *file, int line)
{
  if (mode & CRYPTO_LOCK)
    pthread_mutex_lock(&l->mutex);
  else
    pthread_mutex_unlock(&l->mutex);
}

static void dyn_destroy_function(struct CRYPTO_dynlock_value *l, const char *file, int line)
{
  pthread_mutex_destroy(&l->mutex);
  free(l);
}
#endif

CAMLprim value ocaml_zi_ssl_init(value use_threads)
{
  int i;

#ifdef DLOPEN_CRYPTO
  if (p_SSL_load_error_strings == NULL)
    return Val_unit;
#endif

  p_SSL_library_init();
  p_SSL_load_error_strings();

#ifdef WIN32
  mutex_buf = malloc(p_CRYPTO_num_locks() * sizeof(HANDLE));
#else
  mutex_buf = malloc(p_CRYPTO_num_locks() * sizeof(pthread_mutex_t));
#endif
  assert(mutex_buf);
  for (i = 0; i < p_CRYPTO_num_locks(); i++) {
#ifdef WIN32
    mutex_buf[i] = CreateMutex(NULL, FALSE, NULL);
#else
    pthread_mutex_init(&mutex_buf[i], NULL);
#endif
  }
  p_CRYPTO_set_locking_callback(locking_function);
#ifndef WIN32
  /* Windows does not require id_function, see threads(3) */
  p_CRYPTO_set_id_callback(id_function);
#endif
  p_CRYPTO_set_dynlock_create_callback(dyn_create_function);
  p_CRYPTO_set_dynlock_lock_callback(dyn_lock_function);
  p_CRYPTO_set_dynlock_destroy_callback(dyn_destroy_function);

  return Val_unit;
}

static void finalize_ctx(value block)
{
  EVP_MD_CTX *ctx = Ctx_val(block);
  p_EVP_MD_CTX_destroy(ctx);
}

static struct custom_operations ctx_ops =
{
  "zeroinstall_ssl_hash_ctx",
  finalize_ctx,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default,
  custom_compare_ext_default
};

/* Based on OCaml's unix_utimes function. */
CAMLprim value ocaml_set_mtime(value path, value mtime) {
#ifdef _WIN32
  FILETIME win_time;

  /* Convert seconds since Unix epoch to 100-nano-second intervals since Jan 1, 1601. */
  uint64_t seconds_since_epoch = Double_val(mtime);
  uint64_t seconds_since_1601 = seconds_since_epoch + 11644470000ULL;
  uint64_t hundred_nanos_since_1601 = seconds_since_1601 * 10000000ULL;

  win_time.dwLowDateTime = hundred_nanos_since_1601;
  win_time.dwHighDateTime = hundred_nanos_since_1601 >> 32;

  /* Based on PERL's code.
   * FILE_FLAG_BACKUP_SEMANTICS means it's OK to open directories. */
  HANDLE handle;
  handle = CreateFileA(String_val(path), GENERIC_READ | GENERIC_WRITE,
		       FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
		       OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (handle != INVALID_HANDLE_VALUE) {
    int ok = SetFileTime(handle, NULL, NULL, &win_time);
    CloseHandle(handle);
    if (ok)
      return Val_unit;
  }

  /* On error, fall through to the POSIX code to get the expected error message. */
#endif

  struct utimbuf times;
  times.actime = Double_val(mtime);
  times.modtime = Double_val(mtime);
  if (utime(String_val(path),  &times) == -1) uerror("utimes", path);
  return Val_unit;
}

CAMLprim value ocaml_EVP_MD_CTX_init(value v_alg) {
  CAMLparam1(v_alg);

  EVP_MD_CTX *ctx;

#ifdef DLOPEN_CRYPTO
  if (p_EVP_sha1 == NULL)
    caml_failwith("libcrypto not available (no EVP_sha1 symbol)!");
#endif

  const EVP_MD *digest;

  char *digest_name = String_val(v_alg);
  if (strcmp(digest_name, "sha1") == 0)
    digest = p_EVP_sha1();
  else if (strcmp(digest_name, "sha256") == 0)
    digest = p_EVP_sha256();
  else {
    caml_failwith("Unknown digest name");
    CAMLreturn(Val_unit);	/* (make compiler happy) */
  }

  if ((ctx = p_EVP_MD_CTX_create()) == NULL)
    caml_failwith("EVP_MD_CTX_create: out of memory");

  p_EVP_DigestInit_ex(ctx, digest, NULL);

  CAMLlocal1(block);
  block = caml_alloc_custom(&ctx_ops, sizeof(EVP_MD_CTX*), 0, 1);
  Ctx_val(block) = ctx;

  CAMLreturn(block);
}

CAMLprim value ocaml_DigestUpdate(value v_ctx, value v_str) {
  CAMLparam2(v_ctx, v_str);
  EVP_MD_CTX *ctx = Ctx_val(v_ctx);
  if (p_EVP_DigestUpdate(ctx, String_val(v_str), caml_string_length(v_str)) != 1)
    caml_failwith("EVP_DigestUpdate: failed");
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_DigestFinal_ex(value v_ctx) {
  CAMLparam1(v_ctx);

  EVP_MD_CTX *ctx = Ctx_val(v_ctx);

  unsigned char md_value[EVP_MAX_MD_SIZE];
  unsigned int md_len = 0;

  if (p_EVP_DigestFinal_ex(ctx, md_value, &md_len) != 1)
    caml_failwith("EVP_DigestFinal_ex: failed");

  CAMLlocal1(result);
  result = caml_alloc_string(md_len);
  memmove(String_val(result), md_value, md_len);

  CAMLreturn(result);
}

/* Based on code in extunix (LGPL-2.1) */
CAMLprim value ocaml_0install_uname(value v_unit) {
  CAMLparam1(v_unit);
#ifdef _WIN32
  caml_failwith("No uname on Windows!");
  CAMLreturn(v_unit);
#else
  struct utsname uname_data;

  CAMLlocal2(result, domainname);

  memset(&uname_data, 0, sizeof(uname_data));

  if (uname(&uname_data) == 0) {
    result = caml_alloc(3, 0);
    Store_field(result, 0, caml_copy_string(&(uname_data.sysname[0])));
    Store_field(result, 1, caml_copy_string(&(uname_data.release[0])));
    Store_field(result, 2, caml_copy_string(&(uname_data.machine[0])));
  } else {
    caml_failwith(strerror(errno));
  }

  CAMLreturn(result);
#endif
}

CAMLprim value ocaml_0install_get_terminal_width(value v_unit) {
  CAMLparam1(v_unit);
  int width;
#ifndef _WIN32
  struct winsize w;
  ioctl(STDOUT_FILENO, TIOCGWINSZ, &w);
  width = w.ws_col;
#else
  width = 80;
#endif
  CAMLreturn(Val_int(width));
}
