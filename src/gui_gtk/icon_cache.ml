(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Downloads icons and caches to disk and in memory. *)

open Support
open Support.Common
open Zeroinstall.General

module Feed_url = Zeroinstall.Feed_url

let icon_size = 20

let create config ~fetcher =
  object
    val mutable icon_of_iface : GdkPixbuf.pixbuf option XString.Map.t = XString.Map.empty
    val mutable update_icons = false

    (** Setting this to [true] flushes the in-memory cache and forces a (background) download
     * of each icon that is then requested using [get]. This is set to [true] when the user
     * clicks the Refresh button and set back to [false] after the tree has been rebuilt. *)
    method set_update_icons value =
      if value then
        icon_of_iface <- XString.Map.empty;
      update_icons <- value

    (** Getting a icon from the cache will first try the memory cache, then the disk cache.
        If no icon is found but the feed gives a download location then we start a download in
        the background and call [update] when the new icon arrives. *)
    method get ~update ~feed_provider iface =
      match icon_of_iface |> XString.Map.find_opt iface with
      | Some icon -> icon
      | None ->
          (* Not in the memory cache. Try the disk cache next. *)

          let load_icon path =
            let icon = Gtk_utils.load_png_icon config.system ~width:icon_size ~height:icon_size path in
            icon_of_iface <- icon_of_iface |> XString.Map.add iface icon;
            icon in

          let master_feed = Feed_url.master_feed_of_iface iface in
          let icon_path = Zeroinstall.Feed_cache.get_cached_icon_path config master_feed in
          let icon = icon_path |> pipe_some load_icon in

          (* Download a new icon if we don't have one, or if the user did a 'Refresh'.
           * (if we have an icon_path but we couldn't read it, we don't fetch). *)
          if (icon_path = None || update_icons) && config.network_use <> Offline then (
            (* Prevent further updates *)
            if not (XString.Map.mem iface icon_of_iface) then icon_of_iface <- icon_of_iface |> XString.Map.add iface None;
            Gtk_utils.async (fun () ->
                with_errors_logged (fun f -> f "Icon download failed") @@ fun () ->
                Zeroinstall.Gui.download_icon fetcher feed_provider master_feed >>= fun () ->
                (* If the icon is now in the disk cache, load it into the memory cache and trigger a refresh.
                   If not, we'll be left with None in the cache so we don't try again. *)
                let icon_path = Zeroinstall.Feed_cache.get_cached_icon_path config master_feed in
                Lwt.pause () >|= fun () -> (* Make sure we're not already inside update() *)
                icon_path |> if_some (fun path ->
                    load_icon path |> if_some (fun _ -> update ())
                  )
            )
          );
          (* else: if no icon is available for downloading, more attempts are made later.
             It can happen that no icon is available because the feed was not downloaded yet, in which case
             it's desirable to try again once the feed is available. *)

          icon
  end
