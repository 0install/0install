(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for 0install apps *)

open Support;;

let re_app_name = Str.regexp "^[^./\\\\:=;'\"][^/\\\\:=;'\"]*$";;

let lookup_app name config =
  if Str.string_match re_app_name name 0 then
    Basedir.load_first ("0install.net" +/ "apps" +/ name) config.Config.basedirs.Basedir.config
  else
    None
;;
