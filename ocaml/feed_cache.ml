(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support.Common
module Qdom = Support.Qdom

type interface_config = {
  stability_policy : stability_level option;
  extra_feeds : Feed.feed_import list;
}

(* If we started a check within this period, don't start another one *)
let failed_check_delay = float_of_int (1 * hours)

let is_local_feed uri = Support.Utils.path_is_absolute uri

(* For local feeds, returns the absolute path. *)
let get_cached_feed_path config uri =
  if is_local_feed uri then (
    Some uri
  ) else (
    let cache = config.basedirs.Support.Basedir.cache in
    Support.Basedir.load_first config.system (config_site +/ "interfaces" +/ Escape.escape uri) cache
  )
;;

(** Actually, we list all the cached feeds. Close enough. *)
let list_all_interfaces config =
  let interfaces = ref StringSet.empty in
  let system = config.system in
  let module Basedir = Support.Basedir in

  let check_leaf leaf =
    if leaf.[0] <> '.' then
      let uri = Escape.unescape leaf in
      interfaces := StringSet.add uri !interfaces in

  let scan_dir path =
    match system#readdir (path +/ config_site +/ "interfaces") with
    | Problem _ -> ()
    | Success files -> Array.iter check_leaf files in

  List.iter scan_dir config.basedirs.Basedir.cache;

  !interfaces

(* Note: this was called "update_user_overrides" in the Python *)
let load_iface_config config uri ~known_site_feeds : interface_config =
  try
    let load config_file =
      let root = Qdom.parse_file config.system config_file in
      let stability_policy =
        match ZI.get_attribute_opt "stability-policy" root with
        | None -> None
        | Some s -> Some (Feed.parse_stability s ~from_user:true) in

      let extra_feeds =
        ZI.filter_map root ~f:(fun item ->
          match ZI.tag item with
          | Some "feed" -> (
              let feed_src = ZI.get_attribute "src" item in
              (* (note: 0install 1.9..1.12 used a different scheme and the "site-package" attribute;
                 we deliberately use a different attribute name to avoid confusion) *)
              if ZI.get_attribute_opt "is-site-package" item <> None then (
                (* Site packages are detected earlier. This test isn't completely reliable,
                   since older versions will remove the attribute when saving the config
                   (hence the next test). *)
                None
              ) else if StringSet.mem feed_src known_site_feeds then (
                None
              ) else (
                let (feed_os, feed_machine) = match ZI.get_attribute_opt "arch" item with
                | None -> (None, None)
                | Some arch -> Arch.parse_arch arch in
                let feed_langs = match ZI.get_attribute_opt "langs" item with
                | None -> None
                | Some langs -> Some (Str.split Support.Utils.re_space langs) in
                let open Feed in
                Some { feed_src; feed_os; feed_machine; feed_langs }
              )
          )
          | _ -> None
        ) in

      { stability_policy; extra_feeds; } in

    match Config.load_first_config (config_injector_interfaces +/ Escape.pretty uri) config with
    | Some path -> load path
    | None ->
        (* For files saved by 0launch < 0.49 *)
        match Config.load_first_config (config_site +/ config_prog +/ "user_overrides" +/ Escape.escape uri) config with
        | None -> { stability_policy = None; extra_feeds = [] }
        | Some path -> load path
  with Safe_exception _ as ex -> reraise_with_context ex "... reading configuration settings for interface %s" uri

let get_cached_feed config uri =
  if Support.Utils.starts_with uri "distribution:" then (
    failwith uri
  ) else if is_local_feed uri then (
    let root = Qdom.parse_file config.system uri in
    Some (Feed.parse config.system root (Some uri))
  ) else (
    match get_cached_feed_path config uri with
    | None -> None
    | Some path ->
        let root = Qdom.parse_file config.system path in
        Some (Feed.parse config.system root None)
  )

let get_last_check_attempt config uri =
  let open Support.Basedir in
  let rel_path = config_site +/ config_prog +/ "last-check-attempt" +/ Escape.pretty uri in
  match load_first config.system rel_path config.basedirs.cache with
  | None -> None
  | Some path ->
      match config.system#stat path with
      | None -> None
      | Some info -> Some info.Unix.st_mtime

let is_stale config uri =
  if Support.Utils.starts_with uri "distribution:" then false	(* Ignore (memory-only) PackageKit feeds *)
  else if is_local_feed uri then false                          (* Local feeds are never stale *)
  else (
    let now = config.system#time () in

    let is_stale () =
      match get_last_check_attempt config uri with
      | Some last_check_attempt when last_check_attempt > now -. failed_check_delay ->
          log_debug "Stale, but tried to check recently (%s) so not rechecking now." (Support.Utils.format_time (Unix.localtime last_check_attempt));
          false
      | _ -> true in

    (* TODO: cache this? *)
    match get_cached_feed config uri with
    | None -> is_stale ()
    | Some _feed ->
        (* TODO: cache this? *)
        match (Feed.load_feed_overrides config uri).Feed.last_checked with
        | None ->
            log_debug "Feed '%s' has no last checked time, so needs update" uri;
            is_stale ()
        | Some checked ->
            let staleness = now -. checked in
            log_debug "Staleness for %s is %.2f hours" uri (staleness /. 3600.0);

            match config.freshness with
            | None -> log_debug "Checking for updates is disabled"; false
            | Some threshold when staleness >= (Int64.to_float threshold) -> is_stale ()
            | _ -> false
      )

class feed_provider config =
  let feeds_used = ref StringSet.empty in

  object
    method get_feed url =
      feeds_used := StringSet.add url !feeds_used;
      get_cached_feed config url

    method get_feed_overrides url =
      Feed.load_feed_overrides config url

    method get_iface_config uri =
      (* TODO: site feeds : _add_site_packages *)
      load_iface_config config uri ~known_site_feeds:StringSet.empty

    method get_feeds_used () = !feeds_used
  end
