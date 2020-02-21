open Support.Common

type response =
  [ `Serve
  | `ServeFile of filepath
  | `Chunked
  | `AcceptKey
  | `UnknownKey
  | `Redirect of string
  | `Unexpected
  | `Give404 ]

val with_server :
   ?portable_base:bool ->
   (Zeroinstall.General.config * Fake_system.fake_system ->
    < expect : (string * response) list list -> unit; port : int; terminate : unit Lwt.t > ->
    unit) ->
   unit -> unit
