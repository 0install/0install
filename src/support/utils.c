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

#include <sys/types.h>
#include <errno.h>

#ifndef _WIN32
#include <sys/utsname.h>
#include <sys/ioctl.h>
#include <stdio.h>
#include <unistd.h>
#endif

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
