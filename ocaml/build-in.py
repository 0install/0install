# Needed because ocamlbuild 3.12.1 doesn't support absolute pathnames (4.00.1 does)
import sys
import os
from os.path import relpath
ocaml_build_dir = relpath(sys.argv[1], '.')
os.execvp("make", ["make", 'OCAML_BUILDDIR=' + ocaml_build_dir, "ocaml"])
