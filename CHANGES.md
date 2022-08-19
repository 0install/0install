## v2.18

Changes:

- Add support for ARM64 (Bastian Eicher).

- Add `+` to list of allowed characters in "extract" (Bastian Eicher, #185).

Bug fixes:

- Don't abort if chmod of launcher directory fails.
  We try to make the directory read-only, but this isn't very important.
  It can sometimes fail if running inside a sandbox that prevents modifications to the filesystem.

- Handle implementations that directly conflict with themselves (#180).

- Improve SIGPIPE handling (#162).
  Disable the SIGPIPE signal, so that we handle it as an exception instead, not by killing the process.

Updates for upstream changes:

- Make compatible with Yojson `json` type deprecation (Marek Kubica).
  Yojson 2.0 removes the `json` type, so this code switches to using `t`.

- Replace uses of deprecated `Stdlib.Stream` and `Lwt_unix.yield`.

- Fix new compiler warnings from OCaml 4.12 and 4.13.

- Update .NET Framework detection logic (Bastian Eicher, #178).

- Simplify GUI build using dune's new plugin support (#161).

- Move feed to apps.0install.net (Bastian Eicher).

## v2.17

Solver:

- Add 0install-solver.opam. This makes the solver into a separate opam package.

- Improve display of implementations in diagnostics. Instead of `sha1=3ce644dc725f1d21cfcf02562c76f375944b266a (1)`, show: `v1 (sha1=3ce644dc725f...)`.

- Only report restrictions that affected the result. If a restriction didn't remove any candidates (either because it matched all of them or because another restriction already removed them) then don't bother reporting it. Also, don't bother reporting a restriction that only removed candidates worse than the selected one (if any). For user-provided restrictions, filter the rejects to show only the version the user asked for (unless that would remove all of them). Since we only show the first 5 rejects, this would often mean that the interesting candidates weren't even shown.

- Expose more of the solver diagnostics API. This allows users to format the results in other ways (for example, as a list in a GUI). Also, use formatting boxes instead of manual indentation.

- Add `conflict_class`. This isn't used by 0install, but the new opam backend that uses the 0install solver needs it.

Build:

- Update minimum OCaml version to 4.08. Remove our custom `Option` module and use the new stdlib one instead. Use the new `List.filter_map` from the stdlib instead of our one. Also, rename our `first_match` to `find_map`, to match the name in 4.10.

- Depend on ounit2 for unit-tests. The old `oUnit` is just a transition package that depends on `ounit2` now.

## v2.16

- Update to GTK 3, because Debian is removing GTK 2 support now.
  Note that the systray icon no longer blinks to indicate that action is
  required, as GTK removed this feature. This also updates the static Docker
  images to use Ubuntu 16.04, since 14.04's version of GTK 3 is too old.

- Upgrade to dune 2.1.

## v2.15.2

### Bug fixes

- Don't try to update distribution caches in `--dry-run` mode.
  If we needed to update a cache, the operation would fail with e.g.
  `Bug: 'with_open_out' called in --dry-run mode`.

### Opam package

- Mark obus as required (except on Windows and macOS).
  This is more explicit than just asking users to install it where it makes sense, and also means that the CI will test it.

- Split GTK UI into a separate opam package.
  This makes it easy to install it (using `opam install 0install-gtk`), and means that the CI will test it.

- Update opam metadata to match opam-repository.

### Code cleanups

- Rename "ocaml" directory to "src". There are no other languages here now.

- Make the solver return a `SOLVER_RESULT`.
  The old API was a bit confusing. The user of the solver had to wrap the solver's return to provide a `SOLVER_RESULT` for the diagnostics.
  Now, the user-required bits are in `SOLVER_INPUT` and the solver itself provides the rest.

- Split the solver into its own library. Since the refactoring in 2014
  (see [Simplifying the Solver With Functors](https://roscidus.com/blog/blog/2014/09/17/simplifying-the-solver-with-functors/)),
  the solver isn't really tied to 0install at all, and could be useful for other package managers.

- Generalise the solver's machine groups system.
  This removes the one remaining dependency from the solver to the rest of 0install.

- Rename option functions in solver to match OCaml 4.08.

- Split `Feed_metadata` and `Feed_import` out into their own modules.

- Rename `Feed.feed` to `Feed.t` and make the type abstract.

- Skip rpm2cpio unit test if cpio isn't available. It seems that recent Fedora images provide rpm2cpio, but not cpio.


## v2.15.1

### Changes

- Replace `repo.roscidus.com` feeds with `apps.0install.net` (Bastian Eicher).

- Update fallback host-Python check for new URIs.
  `http://repo.roscidus.com/python/python` is now `https://apps.0install.net/python/python.xml`, etc.

### Bug fixes

- Fix use of nested `Lwt_main.run`. This is now an error with Lwt 5.0.0.

- Fix bad error message when running as root with invalid `$HOME`.
  If we're running as root then we check that `$HOME` is owned by root to avoid
  putting root-owned files in a user's home directory. However, if `$HOME`
  doesn't exist then the error `Unix.ENOENT` was unhelpful.

- Fix bad solver error. The diagnostics system didn't consider dependencies of
  `<command>` elements when trying to explain why a solve failed. It could
  therefore report `Reason for rejection unknown` if a solve failed due to a
  constraint inside one.

- When using `--may-compile` on a local selection, set `local-path`. We already
  gave the full path in `local-path` for other selections, and without this an
  exception is thrown if we try to print the resulting tree.
  e.g. `No digests found for '.'`

### Build system

- Move windows C code to its own library.
  This allows us to use the new `(enabled_if ...)` feature to enable it only on
  Windows, simplifying the `dune` files and avoiding the need for `cppo`.

- Get the `windows_api` object via the `system` object, rather than making it a
  special case.

- Remove windows-specific flags from `utils.c`.
  Looks like these were left over from when there was more code here.
