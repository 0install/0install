#!/usr/bin/env ocaml

(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable (portable version).
    We load unix.cma from the host platform, rather than bundling our own copy. *)

#load "yojson.cma";;
#load "xmlm.cmo";;

#load "dynlink.cma";;
#load "unix.cma";;
#load "str.cma";;
#load "0install.cma";;

module RealSystem = Support.System.RealSystem(Unix);;
let system = new RealSystem.real_system;;
Main.start_if_not_windows system;;

#load "windows.cma";;
Support.Windows_api.windowsAPI := Some Windows.api;;
Main.start system;;
