/* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 */

#define CAML_NAME_SPACE

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <sys/types.h>
#ifndef _WIN32
#include <utime.h>
#else
#include <sys/utime.h>
#endif

/* Based on OCaml's unix_utimes function. */
CAMLprim value ocaml_set_mtime(value path, value mtime)
{
  struct utimbuf times;
  times.actime = Double_val(mtime);
  times.modtime = Double_val(mtime);
  if (utime(String_val(path),  &times) == -1) uerror("utimes", path);
  return Val_unit;
}
