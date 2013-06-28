(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common

class base_distribution : distribution =
  object
    method is_installed elem =
      log_warning "FIXME: Assuming distribution package %s version %s is still installed"
                  (ZI.get_attribute "id" elem) (ZI.get_attribute "version" elem);
      true
  end
;;

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version of each distribution package currently installed. *)
module Cache =
  struct

    type cache_data = {
      mutable mtime : int;
      mutable size : int;
      mutable rev : int;
      mutable contents : string StringMap.t;
    }

    (* Note: [format_version] doesn't make much sense. If the format changes, just use a different [cache_leaf],
       otherwise you'll be fighting with other versions of 0install. *)
    class cache (config:General.config) (cache_leaf:string) (source:filepath) (format_version:int) =
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0; size = -1; rev = -1; contents = StringMap.empty }

        val cache_path = Basedir.save_path config.system (config_site +/ config_prog +/ cache_leaf) config.basedirs.Basedir.cache

        (** Reload the values from disk (even if they're out-of-date). *)
        method load_cache () =
          data.mtime <- -1;
          data.size <- -1;
          data.rev <- -1;
          data.contents <- StringMap.empty;

          if Sys.file_exists source then (
            let load_cache ch =
              let headers = ref true in
              while !headers do
                match input_line ch with
                | "" -> headers := false
                | line ->
                    (* log_info "Cache header: %s" line; *)
                    match Utils.split_pair re_equals line with
                    | ("mtime", mtime) -> data.mtime <- int_of_string mtime
                    | ("size", size) -> data.size <- int_of_string size
                    | ("format", rev) -> data.rev <- int_of_string rev
                    | _ -> ()
              done;

              try
                while true do
                  let line = input_line ch in
                  let (key, value) = Utils.split_pair re_equals line in
                  data.contents <- StringMap.add key value data.contents;
                done
              with End_of_file -> ()
              
              in
            config.system#with_open load_cache cache_path
          )

        (** Check cache is still up-to-date. Clear it not. *)
        method ensure_valid () =
          let info = Unix.stat source in
          if data.mtime <> int_of_float info.Unix.st_mtime then (
            log_info "Modification time of %s has changed; invalidating cache" source;
            raise Fallback_to_Python
          ) else if data.size <> info.Unix.st_size then (
            log_info "Size of %s has changed; invalidating cache" source;
            raise Fallback_to_Python
          ) else if data.rev <> format_version then (
            log_info "Format of cache %s has changed; invalidating cache" cache_path;
            raise Fallback_to_Python
          )

        method get (key:string) : string option =
          self#ensure_valid ();
          try Some (StringMap.find key data.contents)
          with Not_found -> None

        initializer self#load_cache ()
      end
  end

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  class debian_distribution config : distribution =
    object
      val cache = new Cache.cache config "dpkg-status.cache" dpkg_db_status 2

      method is_installed elem =
        match ZI.get_attribute_opt "package" elem with
        | None -> (log_warning "Missing 'package' attribute"; false)
        | Some package ->
            match cache#get package with
            | None -> raise Fallback_to_Python    (* Not installed, or need to repopulate the cache *)
            | Some data ->
                let installed_version, machine = Utils.split_pair re_tab data in
                let installed_id = Printf.sprintf "package:deb:%s:%s:%s" package installed_version machine in
                let sel_id = ZI.get_attribute "id" elem in
                (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
                sel_id = installed_id
    end
end

module Arch = struct
  let arch_db = "/var/lib/pacman"

  class arch_distribution () : distribution =
    object
      method is_installed elem =
        (* We should never get here, because we always set quick-test-* *)
        Qdom.log_elem Logging.Info "Old selections file; forcing an update of" elem;
        false
    end
end

let get_host_distribution config : distribution =
  (*
  let rpm_db_packages = "/var/lib/rpm/Packages" in
  let slack_db = "/var/log/packages" in
  let pkg_db = "/var/db/pkg" in
  let macports_db = "/opt/local/var/macports/registry/registry.db" in
  let cygwin_log = "/var/log/setup.log" in
  *)

  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      if x Debian.dpkg_db_status && (Unix.stat Debian.dpkg_db_status).Unix.st_size > 0 then
        new Debian.debian_distribution config
      else if x Arch.arch_db then
        new Arch.arch_distribution ()
      else
        new base_distribution

  | "Win32" | "Cygwin" ->
      new base_distribution

  | _ ->
      new base_distribution
;;

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, use
    them to check. Otherwise, call the appropriate method on [config.distro]. *)
let is_installed config elem =
  match ZI.get_attribute_opt "quick-test-file" elem with
  | None -> (Lazy.force config.distro)#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match ZI.get_attribute_opt "quick-test-mtime" elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (int_of_float info.Unix.st_mtime) = int_of_string required_mtime
