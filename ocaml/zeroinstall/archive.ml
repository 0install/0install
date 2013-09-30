(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
module U = Support.Utils

type mime_type = string

let type_from_url url =
  let re_extension = Str.regexp "\\(\\.tar\\)?\\.[^./]+$" in
  let ext =
    try U.string_tail url @@ Str.search_forward re_extension url 0
    with Not_found -> "" in
  match String.lowercase ext with
  | ".tar.bz2"  -> "application/x-bzip-compressed-tar"
  | ".tar.gz"   -> "application/x-compressed-tar"
  | ".tar.lzma" -> "application/x-lzma-compressed-tar"
  | ".tar.xz"   -> "application/x-xz-compressed-tar"
  | ".rpm" -> "application/x-rpm"
  | ".deb" -> "application/x-deb"
  | ".tbz" -> "application/x-bzip-compressed-tar"
  | ".tgz" -> "application/x-compressed-tar"
  | ".tlz" -> "application/x-lzma-compressed-tar"
  | ".txz" -> "application/x-xz-compressed-tar"
  | ".tar" -> "application/x-tar"
  | ".zip" -> "application/zip"
  | ".cab" -> "application/vnd.ms-cab-compressed"
  | ".dmg" -> "application/x-apple-diskimage"
  | ".gem" -> "application/x-ruby-gem"
  | _ -> raise_safe "No 'type' attribute on archive, and I can't guess from the name (%s)" url

let check_type_ok system =
  let missing name = U.find_in_path system name = None in
  function
    | "application/x-rpm" -> if missing "rpm2cpio" then
        raise_safe "This package looks like an RPM, but you don't have the rpm2cpio command \
                    I need to extract it. Install the \"rpm\" package first (this works even if \
                    you're on a non-RPM-based distribution such as Debian)."
    | "application/x-deb" -> if missing "ar" then
        raise_safe "This package looks like a Debian package, but you don't have the \"ar\" command \
                     I need to extract it. Install the package containing it (sometimes called \"binutils\") \
                     first. This works even if you're on a non-Debian-based distribution such as Red Hat)."
    | "application/x-bzip-compressed-tar" -> ()	(* We"ll fall back to Python"s built-in tar.bz2 support *)
    | "application/zip" -> if missing "unzip" then
        raise_safe "This package looks like a zip-compressed archive, but you don't have the \"unzip\" command \
                    I need to extract it. Install the package containing it first."
    | "application/vnd.ms-cab-compressed" -> if missing "cabextract" then
        raise_safe "This package looks like a Microsoft Cabinet archive, but you don't have the \"cabextract\" command \
                    I need to extract it. Install the package containing it first."
    | "application/x-apple-diskimage" -> if missing "hdiutil" then
        raise_safe "This package looks like a Apple Disk Image, but you don't have the \"hdiutil\" command \
                    I need to extract it."
    | "application/x-lzma-compressed-tar" -> () (* We can get it through Zero Install *)
    | "application/x-xz-compressed-tar" -> if missing "unxz" then
        raise_safe "This package looks like a xz-compressed package, but you don't have the \"unxz\" command \
                    I need to extract it. Install the package containing it (it's probably called \"xz-utils\") first."
    | "application/x-compressed-tar" | "application/x-tar" | "application/x-ruby-gem" -> ()
    | mime_type ->
        raise_safe "Unsupported archive type \"%s\" (for 0install version %s)" mime_type About.version
