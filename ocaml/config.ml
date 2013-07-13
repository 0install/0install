(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Configuration settings *)

open General;;

(** {2 Functions} *)

(** [get_default_config path_to_0install] creates a configuration from the current environment.
    [path_to_0install] is used when creating launcher scripts. If it contains no slashes, then
    we search for it in $PATH.
  *)
let get_default_config system path_to_0install =
  let abspath_0install = if String.contains path_to_0install Filename.dir_sep.[0] then
    Support.Utils.abspath system path_to_0install
  else
    Support.Utils.find_in_path_ex system path_to_0install
  in

  let basedirs = Support.Basedir.get_default_config system in

  let rec config = {
    basedirs;
    stores = Stores.get_default_stores basedirs;
    abspath_0install;
    freshness = Some (Int64.of_int (30 * days));
    distro = lazy (Distro.get_host_distribution config);
    system;
  } in

  let handle_ini_mapping = function
    | "global" -> (function
      | ("freshness", freshness) ->
          let value = Int64.of_string freshness in
          if value > 0L then
            config.freshness <- Some value
          else
            config.freshness <- None
      | _ -> ()
    )
    | _ -> ignore in    (* other [sections] *)

  let () = match Support.Basedir.load_first config.system config_injector_global basedirs.Support.Basedir.config with
  | None -> ()
  | Some path -> Support.Utils.parse_ini config.system handle_ini_mapping path in

  config
;;

let load_first_config rel_path config =
  let open Support in
  Basedir.load_first config.system rel_path config.basedirs.Basedir.config
;;
