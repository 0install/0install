(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General

let is_installed elem =
  match ZI.get_attribute_opt "quick-test-file" elem with
  | Some file -> Sys.file_exists file
  | None ->
      (* TODO *)
      log_info "Assuming distribution package %s version %s is still installed"
               (ZI.get_attribute "id" elem) (ZI.get_attribute "version" elem);
      true
