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
#endif

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
