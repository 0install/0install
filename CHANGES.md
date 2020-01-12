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
