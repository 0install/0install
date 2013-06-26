open OUnit
open Support.Common

class fake_system =
  object (_ : #system)
    val now = ref 0.0
    val mutable env = StringMap.empty

    method time () = !now

    method with_open = failwith "file access"
    method mkdir = failwith "file access"
    method file_exists = failwith "file access"
    method lstat = failwith "file access"
    method atomic_write = failwith "file access"

    method exec = failwith "exec"
    method create_process = failwith "exec"
    method getcwd = failwith "getcwd"

    method getenv name =
      try Some (StringMap.find name env)
      with Not_found -> None

    method putenv name value =
      env <- StringMap.add name value env
  end
;;

let format_list l = "[" ^ (String.concat "; " l) ^ "]"
let equal_str_lists = assert_equal ~printer:format_list

let test_basedir () =
  let system = new fake_system in
  let open Support.Basedir in

  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"No $HOME1" ["/root/.config"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"No $HOME2" ["/root/.cache"; "/var/cache"] bd.cache;
  equal_str_lists ~msg:"No $HOME3" ["/root/.local/share"; "/usr/local/share"; "/usr/share"] bd.data;

  system#putenv "HOME" "/home/bob";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"$HOME1" ["/home/bob/.config"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"$HOME2" ["/home/bob/.cache"; "/var/cache"] bd.cache;
  equal_str_lists ~msg:"$HOME3" ["/home/bob/.local/share"; "/usr/local/share"; "/usr/share"] bd.data;

  system#putenv "XDG_CONFIG_HOME" "/home/bob/prefs";
  system#putenv "XDG_CACHE_DIRS" "";
  system#putenv "XDG_DATA_DIRS" "/data1:/data2";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"XDG1" ["/home/bob/prefs"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"XDG2" ["/home/bob/.cache"] bd.cache;
  equal_str_lists ~msg:"XDG3" ["/home/bob/.local/share"; "/data1"; "/data2"] bd.data;

  system#putenv "ZEROINSTALL_PORTABLE_BASE" "/mnt/0install";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"PORT-1" ["/mnt/0install/config"] bd.config;
  equal_str_lists ~msg:"PORT-2" ["/mnt/0install/cache"] bd.cache;
  equal_str_lists ~msg:"PORT-3" ["/mnt/0install/data"] bd.data;
;; 

(* Name the test cases and group them together *)
let suite = 
"suite">:::[
 "test_basedir">:: test_basedir;
];;

let () = Printexc.record_backtrace true;;

let _ = run_test_tt_main suite;;

Format.print_newline ()
