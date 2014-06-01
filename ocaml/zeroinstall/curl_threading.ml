(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Use Lwt if possible, or native threads if not.
 * Native threads require us to initialise openssl for threading, which gives us a run-time dependency on it.
 * Since openssl has poor ABI compatibility, this makes the 0install binary less portable. *)

IFDEF HAVE_OCURL_LWT THEN
let init () = ()
let run_in_main fn = fn ()
let detach fn = fn ()
let perform connection when_done =
  Lwt.bind (Curl_lwt.perform connection) (function
    | Curl.CURLE_OK -> Lwt.return (when_done ())
    | code -> raise Curl.(CurlException (code, errno code, strerror code))
  )
let catch f g = Lwt.catch f (fun ex -> Lwt.return (g ex))
ELSE
let init () =
  Lwt_preemptive.init 0 100 (Support.Common.log_warning "%s");
  (* from dx-ocaml *)
  Ssl.init ~thread_safe:true ()  (* Performs incantations to ensure thread-safety of OpenSSL *)

let run_in_main fn = Lwt_preemptive.run_in_main (fun () -> Lwt.return (fn ()))
let detach fn = Lwt_preemptive.detach fn ()
let perform connection when_done = Curl.perform connection; when_done ()
let catch f g =
  try f ()
  with ex -> g ex
ENDIF
