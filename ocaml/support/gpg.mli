(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Use GnuPG to check the digital signatures on feeds. *)

type fingerprint = string
type timestamp = float

type sig_error =
  | UnsupportedAlgorithm of string
  | UnknownKey of string
  | UnknownSigError of int

type valid_details = {
  fingerprint : fingerprint;
  timestamp : timestamp;
}

type signature =
  | ValidSig of valid_details
  | BadSig of string      (* Message has been tampered with *)
  | ErrSig of sig_error

type key_info = {
  name : string option
}

(** A human-readable description of a signature. *)
val string_of_sig : signature -> string

(** Run "gpg --import" with this data as stdin. *)
val import_key : Common.system -> string -> unit Lwt.t

(** Get the first human-readable name from the details. *)
val get_key_name : Common.system -> fingerprint -> string option Lwt.t

(** Verify the GPG signature at the end of data (which must be XML).
 * Returns the list of signatures found, plus the raw stderr from gpg (which may be useful if
 * you need to report an error). *)
val verify : Common.system -> string -> (signature list * string) Lwt.t

(** Load a set of keys at once. Returns a map from fingerprints to information. *)
val load_keys : Common.system -> fingerprint list -> key_info Common.StringMap.t Lwt.t
