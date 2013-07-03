/* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <windows.h>
#include <winerror.h>
#include <shlobj.h>

static value get_shared_folder(int nFolder) {
    TCHAR path[MAX_PATH];

    if(SUCCEEDED(SHGetFolderPath(NULL, nFolder, NULL, 0, path)))
        return caml_copy_string(path);

    caml_failwith("get_local_appdata");
    return Val_unit;
}

CAMLprim value caml_win_get_appdata(value v_unit)
{
    CAMLparam1(v_unit);
    CAMLreturn(get_shared_folder(CSIDL_APPDATA | CSIDL_FLAG_CREATE));
}

CAMLprim value caml_win_get_local_appdata(value v_unit)
{
    CAMLparam1(v_unit);
    CAMLreturn(get_shared_folder(CSIDL_LOCAL_APPDATA | CSIDL_FLAG_CREATE));
}

CAMLprim value caml_win_get_common_appdata(value v_unit)
{
    CAMLparam1(v_unit);
    CAMLreturn(get_shared_folder(CSIDL_COMMON_APPDATA | CSIDL_FLAG_CREATE));
}
