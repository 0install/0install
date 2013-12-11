OCAML_BUILDDIR=../build/ocaml
TYPE=native
DEBUG=-cflags -g
OCAMLBUILD=ocamlbuild -j 0 ${DEBUG} -use-ocamlfind -build-dir "${OCAML_BUILDDIR}"
ifeq ($(OS), Windows_NT)
  OCAMLBUILDFLAGS = -lflag -cclib -lflag -lshell32
endif
MS_SDK:="/cygdrive/c/Program Files/Microsoft SDKs/Windows/v7.0/Bin"
TEST_BINARY=./${OCAML_BUILDDIR}/tests/test.$(TYPE)

.PHONY: all ocaml doc clean tags test

all: build_dir ocaml test

build_dir:
	[ -d "${OCAML_BUILDDIR}" ] || mkdir -p "${OCAML_BUILDDIR}"

test: ocaml
	@if [ -f "${TEST_BINARY}" ]; then "${TEST_BINARY}"; else echo "Unit-tests not compiled, so skipping tests"; fi

# Build static version (of $TYPE)
ocaml: build_dir
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) "all-${TYPE}.otarget"
	#cp 0install.ml "$(OCAML_BUILDDIR)/"
	if [ "$(OS)" = "Windows_NT" ];then make ocaml_windows; else make ocaml_posix; fi

# For static Windows version, we also need the runenv.native helper.
# Also, we need an XML manifest, or Windows 7 won't run it because it has "install" in its name.
ocaml_windows:
	cp ${OCAML_BUILDDIR}/static_0install.$(TYPE) ${OCAML_BUILDDIR}/0install.exe
	cp ${OCAML_BUILDDIR}/runenv.native ${OCAML_BUILDDIR}/0install-runenv.exe
	${MS_SDK}/mt.exe -nologo -manifest 0install.exe.manifest -outputresource:"${OCAML_BUILDDIR}/0install.exe;#1"
	${MS_SDK}/mt.exe -nologo -manifest 0install.exe.manifest -outputresource:"${OCAML_BUILDDIR}/0install-runenv.exe;#1"
	ln -f "${OCAML_BUILDDIR}/0install.exe" "${OCAML_BUILDDIR}/0launch.exe"

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
	$(OCAMLBUILD) -clean

tags:
	ctags -R [a-z]*
