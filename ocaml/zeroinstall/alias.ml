(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling the old aliases. *)

open Support.Common
open General

type alias_info = {
  uri : iface_uri;
  command : string option;
  main : string option;
}

(** The static start of the old v1 alias scripts. *)
let v1_header = "#!/bin/sh\n\
if [ \"$*\" = \"--versions\" ]; then\n\
\  exec 0launch -gd "

(** The static start of the old v2 alias scripts. *)
let v2_header = "#!/bin/sh\n\
exec 0launch "

let re_launch = Str.regexp "^ *exec 0launch  ?\\(--\\(main\\|command\\) '\\(.*\\)' \\)?'\\([^']*\\)' \"\\$@\"$"

let max_len = max (String.length v1_header) (String.length v2_header)

(** Read up to [n] bytes from [ch] (less if we hit end-of-file. *)
let read_upto n ch : string =
  let buf = String.create n in
  let saved = ref 0 in
  try
    while !saved < n do
      let got = input ch buf !saved (n - !saved) in
      if got = 0 then
        raise End_of_file;
      assert (got > 0);
      saved := !saved + got
    done;
    buf
  with End_of_file ->
    String.sub buf 0 !saved

let unescape s = Str.global_replace (Str.regexp_string "\\'") s "'"

let extract_info ch =
  let line = input_line ch in
  (* [line] contains the 0launch line *)
  if Str.string_match re_launch line 0 then (
    let uri = Str.matched_group 4 line in
    let opt = try Str.matched_group 2 line with Not_found -> "" in
    let main = if opt = "main" then Some (unescape @@ Str.matched_group 3 line) else None in
    let command = if opt = "command" then Some (unescape @@ Str.matched_group 3 line) else None in
    Some {
      uri;
      command;
      main;
    }
  ) else (
    log_warning "No match for '%s'" line;
    None
  )

let parse_script (system:system) path =
  let starts_with = Support.Utils.starts_with in
  system#with_open_in [Open_rdonly; Open_text] 0 path (fun ch ->
    let actual = read_upto max_len ch in
    if starts_with actual v1_header then (
      seek_in ch 0;
      for _i = 1 to 4 do ignore @@ input_line ch done;
      extract_info ch
    ) else if starts_with actual v2_header then (
      seek_in ch 0;
      ignore @@ input_line ch;
      extract_info ch
    ) else (
      None
    )
  )

let is_alias_script system path = parse_script system path <> None
