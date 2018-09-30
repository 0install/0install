(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type payload = (string * string list ref)

exception T of payload

let msg = fst

let v ?(ctx=[]) f =
  f |> Format.kasprintf @@ fun msg ->
  T (msg, ref ctx)

let failf ?(ctx=[]) fmt =
  fmt |> Format.kasprintf @@ fun msg ->
  raise (T (msg, ref ctx))

let reraise_with ex fmt =
  fmt |> Format.kasprintf @@ fun context ->
  begin match ex with
    | T (_, old_contexts) -> old_contexts := context :: !old_contexts
    | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exn.T!" context
  end;
  raise ex

let with_info note f =
  Lwt.catch f
    (function
      | T (_, old_contexts) as ex ->
        note @@ Format.kasprintf (fun x -> old_contexts := x :: !old_contexts);
        raise ex
      | ex -> Lwt.fail ex
    )

let pp_ctx_line f line =
  Format.fprintf f "@,%s" line

let pp f (msg, context) =
  Format.fprintf f "@[<v>%s%a@]" msg
    (Format.pp_print_list ~pp_sep:(fun _ _ -> ()) pp_ctx_line) (List.rev !context)

let to_string = function
  | T e -> Some (Format.asprintf "%a" pp e)
  | _ -> None

let () = Printexc.register_printer to_string
