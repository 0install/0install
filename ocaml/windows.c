/* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 */

#define _WIN32_WINNT 0x0501 //targets XP or later

#define CAML_NAME_SPACE

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

CAMLprim value caml_win_read_registry_string(value v_subkey, value v_value, value v_wow)
{
    CAMLparam3(v_subkey, v_value, v_wow);

    HKEY resultHKey = NULL;
    char resultString[4096];
    DWORD resultSize = sizeof(resultString);
    REGSAM flags = KEY_READ;
    int wow = Int_val(v_wow);
    DWORD typ = REG_SZ;

    if (wow == 1) {
	flags |= KEY_WOW64_32KEY;
    } else if (wow == 2) {
	flags |= KEY_WOW64_64KEY;
    }

    if (RegOpenKeyEx(HKEY_LOCAL_MACHINE, String_val(v_subkey), 0, flags, &resultHKey) != ERROR_SUCCESS) {
	caml_failwith("RegOpenKeyEx");
    } else if (RegQueryValueEx(resultHKey, String_val(v_value), 0, &typ, (LPBYTE) &resultString, &resultSize) != ERROR_SUCCESS) {
	caml_failwith("RegQueryValue");
    } else {
	if (resultSize < 0 || resultSize >= sizeof(resultString))
	    caml_failwith("Registry value too big");
	resultString[resultSize] = '\0';

	CAMLlocal1(result);
	result = caml_copy_string(resultString);

	RegCloseKey(resultHKey);
	resultHKey = NULL;

	CAMLreturn(result);
    }
}

CAMLprim value caml_win_read_registry_int(value v_subkey, value v_value, value v_wow)
{
    CAMLparam3(v_subkey, v_value, v_wow);

    HKEY resultHKey = NULL;
    DWORD resultDWord = 0;
    DWORD resultSize = sizeof(resultDWord);
    REGSAM flags = KEY_READ;
    int wow = Int_val(v_wow);
    DWORD typ = REG_DWORD;

    if (wow == 1) {
	flags |= KEY_WOW64_32KEY;
    } else if (wow == 2) {
	flags |= KEY_WOW64_64KEY;
    }

    if (RegOpenKeyEx(HKEY_LOCAL_MACHINE, String_val(v_subkey), 0, flags, &resultHKey) != ERROR_SUCCESS) {
	caml_failwith("RegOpenKeyEx");
    } else if (RegQueryValueEx(resultHKey, String_val(v_value), 0, &typ, (LPBYTE) &resultDWord, &resultSize) != ERROR_SUCCESS) {
	caml_failwith("RegQueryValue(int)");
    } else {
	RegCloseKey(resultHKey);
	resultHKey = NULL;

	CAMLreturn(Val_int(resultDWord));
    }
}
