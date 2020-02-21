(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Some constant strings used in the XML (to avoid typos) *)

module FeedAttr =
  struct
    let id = "id"
    let command = "command"
    let main = "main"
    let self_test = "self-test"
    let stability = "stability"
    let value_testing = "testing"
    let importance = "importance"
    let version = "version"
    let version_modifier = "version-modifier"      (* This is stripped out and moved into attr_version *)
    let released = "released"
    let os= "os"
    let use = "use"
    let local_path = "local-path"
    let lang = "lang"
    let langs = "langs"
    let interface = "interface"
    let src = "src"
    let if_0install_version = "if-0install-version"
    let distribution = "distribution"
    let uri = "uri"
    let from_feed = "from-feed"
    let doc_dir = "doc-dir"
    let package = "package"
    let quick_test_file = "quick-test-file"
    let quick_test_mtime = "quick-test-mtime"
    let license = "license"
  end

module FeedConfigAttr =
  struct
    let user_stability = "user-stability"
  end

module IfaceConfigAttr =
  struct
    let stability_policy = "stability_policy"
    let is_site_package = "is-site-package"
    let src = "src"
    let arch = "arch"
  end
