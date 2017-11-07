OCAML_BUILDDIR=../build/ocaml

ifeq ($(shell uname -o),Cygwin)
  BUILDDIR_NATIVE = $(shell cygpath -w ${OCAML_BUILDDIR})
else
  BUILDDIR_NATIVE = ${OCAML_BUILDDIR}
endif

TYPE=native
OCAMLBUILD=ocamlbuild -j 0 -use-ocamlfind -plugin-tag 'package(cppo_ocamlbuild)' -build-dir "${BUILDDIR_NATIVE}"
WINDOWS_LIBS = $(shell dirname $(shell which ocamlc))
ifeq ($(OS), Windows_NT)
  OCAMLBUILDFLAGS = -lflag -cclib -lflag -lshell32
endif
TEST_BINARY=${OCAML_BUILDDIR}/tests/test.$(TYPE)
# Windows only: Set WINDRES, if it is neither called i686-w64-mingw32-windres.exe (i686)
# nor x86_64-w64-mingw32-windres.exe (x86_64).
# WINDRES=i686-w64-windres
# export WINDRES

.PHONY: all ocaml doc clean tags test

all: build_dir ocaml test

build_dir:
	[ -d "${OCAML_BUILDDIR}" ] || mkdir -p "${OCAML_BUILDDIR}"

test: ocaml
	@if [ -f "${TEST_BINARY}" ]; then "${TEST_BINARY}"; else echo "Unit-tests not compiled, so skipping tests"; fi

# Build static version (of $TYPE)
ocaml: build_dir
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) "all-${TYPE}.otarget"
	if [ -f "${OCAML_BUILDDIR}/runenv.native" ];then $(MAKE) ocaml_windows; else $(MAKE) ocaml_posix; fi

# For static Windows version, we also need the runenv.native helper.
ocaml_windows:
	cp ${OCAML_BUILDDIR}/static_0install.$(TYPE) ${OCAML_BUILDDIR}/0install.exe
	cp ${OCAML_BUILDDIR}/runenv.native ${OCAML_BUILDDIR}/0install-runenv.exe
	ln -f "${OCAML_BUILDDIR}/0install.exe" "${OCAML_BUILDDIR}/0launch.exe"
	-cp "${WINDOWS_LIBS}/libeay32.dll" "${WINDOWS_LIBS}/ssleay32.dll" "${OCAML_BUILDDIR}"

ocaml_posix:
	cp ${OCAML_BUILDDIR}/static_0install.$(TYPE) ${OCAML_BUILDDIR}/0install
	-[ -L 0install ] || ln -s ../build/ocaml/0install 0install
	@# so Vim can find the type annotations:
	-[ -L _build -o -e _build ] || ln -s ${OCAML_BUILDDIR} _build
	ln -f "${OCAML_BUILDDIR}/0install" "${OCAML_BUILDDIR}/0launch"

doc:
	ocp-pack -o support.ml.tmp support/logging.ml support/common.ml support/utils.ml support/basedir.ml support/qdom.ml support/system.ml
	echo '(** General support code; not 0install-specific *)' > support.ml
	cat support.ml.tmp >> support.ml
	rm support.ml.tmp
	$(OCAMLBUILD) 0install.docdir/index.html
	rm support.ml

# Results turn up in the "html" directory after running the unit-tests.
coverage:
	rm -f bisect*.out
	OCAML_COVERAGE=true make test
	ocaml-bisect-report -I "${OCAML_BUILDDIR}" -html html "bisect0001.out"

clean:
	mkdir -p ${OCAML_BUILDDIR}
	$(OCAMLBUILD) -clean

tags:
	ctags -R [a-z]*
