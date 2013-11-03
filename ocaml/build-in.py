# Needed because ocamlbuild 3.12.1 doesn't support absolute pathnames (4.00.1 does)
# And 4.01.0 fails when given a relative path ("Failure: Pathname.normalize_list: .. is forbidden here.")
import sys
import os
import subprocess

if not hasattr(subprocess, 'check_output'):
    def check_output(*popenargs, **kwargs):
        if 'stdout' in kwargs:
            raise ValueError('stdout argument not allowed, it will be overridden.')
        process = subprocess.Popen(stdout=subprocess.PIPE, *popenargs, **kwargs)
        output, unused_err = process.communicate()
        retcode = process.poll()
        if retcode:
            cmd = kwargs.get("args")
            if cmd is None:
                cmd = popenargs[0]
            raise subprocess.CalledProcessError(retcode, cmd, output=output)
        return output
    subprocess.check_output = check_output

ocaml_version = subprocess.check_output(["ocamlbuild", "-version"], universal_newlines = True).split(' ', 1)[1]
if ocaml_version.startswith('3'):
	from os.path import relpath
	ocaml_build_dir = relpath(sys.argv[1], '.')
else:
	ocaml_build_dir = sys.argv[1]

print("dir", ocaml_build_dir)

# Hack: when we can depend on a full OCaml feed with the build tools, we can remove this.
# Until then, we need to avoid trying to compile against the limited runtime environment.
if 'OCAMLLIB' in os.environ:
	del os.environ['OCAMLLIB']

os.execvp("make", ["make", 'OCAML_BUILDDIR=' + ocaml_build_dir, "ocaml"])
