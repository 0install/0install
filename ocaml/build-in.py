# Needed because ocamlbuild 3.12.1 doesn't support absolute pathnames (4.00.1 does)
import sys
import os
from os.path import relpath
ocaml_build_dir = relpath(sys.argv[1], '.')

# Hack: when we can depend on a full OCaml feed with the build tools, we can remove this.
# Until then, we need to avoid trying to compile against the limited runtime environment.
if 'OCAMLLIB' in os.environ:
	del os.environ['OCAMLLIB']

os.execvp("make", ["make", 'OCAML_BUILDDIR=' + ocaml_build_dir, "ocaml"])
