/* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 */

#define CAML_NAME_SPACE

#include <string.h>

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

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

#define Ctx_val(v) (*((EVP_MD_CTX**)Data_custom_val(v)))

static void finalize_ctx(value block)
{
  EVP_MD_CTX *ctx = Ctx_val(block);
  EVP_MD_CTX_destroy(ctx);
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
  struct utimbuf times;
  times.actime = Double_val(mtime);
  times.modtime = Double_val(mtime);
  if (utime(String_val(path),  &times) == -1) uerror("utimes", path);
  return Val_unit;
}

CAMLprim value ocaml_EVP_MD_CTX_init(value v_alg) {
  CAMLparam1(v_alg);

  EVP_MD_CTX *ctx;

  const EVP_MD *digest;

  char *digest_name = String_val(v_alg);
  if (strcmp(digest_name, "sha1") == 0)
    digest = EVP_sha1();
  else if (strcmp(digest_name, "sha256") == 0)
    digest = EVP_sha256();
  else {
    caml_failwith("Unknown digest name");
    CAMLreturn(Val_unit);	/* (make compiler happy) */
  }

  if ((ctx = EVP_MD_CTX_create()) == NULL)
    caml_failwith("EVP_MD_CTX_create: out of memory");

  EVP_DigestInit_ex(ctx, digest, NULL);

  CAMLlocal1(block);
  block = caml_alloc_custom(&ctx_ops, sizeof(EVP_MD_CTX*), 0, 1);
  Ctx_val(block) = ctx;

  CAMLreturn(block);
}

CAMLprim value ocaml_DigestUpdate(value v_ctx, value v_str) {
  CAMLparam2(v_ctx, v_str);
  EVP_MD_CTX *ctx = Ctx_val(v_ctx);
  if (EVP_DigestUpdate(ctx, String_val(v_str), caml_string_length(v_str)) != 1)
    caml_failwith("EVP_DigestUpdate: failed");
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_DigestFinal_ex(value v_ctx) {
  CAMLparam1(v_ctx);

  EVP_MD_CTX *ctx = Ctx_val(v_ctx);

  unsigned char md_value[EVP_MAX_MD_SIZE];
  unsigned int md_len = 0;

  if (EVP_DigestFinal_ex(ctx, md_value, &md_len) != 1)
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
