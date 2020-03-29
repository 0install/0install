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
