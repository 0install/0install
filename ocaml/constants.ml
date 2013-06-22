(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful 0install constants *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end;;

module ZI = Qdom.NsQuery (ZI_NS);;
