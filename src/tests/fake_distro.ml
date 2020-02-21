(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

let fake_packagekit status =
  object (_ : Zeroinstall.Packagekit.packagekit)
    method status = Lwt.return status
    method get_impls (package_name:string) =
      log_info "packagekit: get_impls(%s)" package_name;
      { Zeroinstall.Packagekit.results = []; problems = [] }
    method check_for_candidates ~ui:_ ~hint (package_names:string list) : unit Lwt.t =
      log_info "packagekit: check_for_candidates(%s) for %s" (String.concat ", " package_names) hint;
      Lwt.return ()
    method install_packages _ui _names = failwith "install_packages"
  end


let make config =
  let packagekit = lazy (fake_packagekit `Ok) in
  Zeroinstall.Distro_impls.generic_distribution ~packagekit config |> Zeroinstall.Distro.of_provider
