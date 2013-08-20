OCAML_BUILDDIR=../build/ocaml
TYPE=native
DEBUG=-cflags -g
OCAMLBUILD=ocamlbuild ${DEBUG} -use-ocamlfind -build-dir "${OCAML_BUILDDIR}"
TARGETS=static_0install.$(TYPE) main.cma support/windows.cma tests/test.$(TYPE)
ifeq ($(OS), Windows_NT)
  TARGETS += runenv.native
  OCAMLBUILDFLAGS = -lflag -cclib -lflag -lshell32
endif
MS_SDK:="/cygdrive/c/Program Files/Microsoft SDKs/Windows/v7.0/Bin"

.PHONY: all ocaml doc clean tags test

all: build_dir ocaml test

build_dir:
	[ -d "${OCAML_BUILDDIR}" ] || mkdir -p "${OCAML_BUILDDIR}"

test: ocaml
	(cd tests && OCAML_BUILDDIR=../${OCAML_BUILDDIR} ../${OCAML_BUILDDIR}/tests/test.$(TYPE))

# Build portable bytecode and static version (of $TYPE)
ocaml: build_dir
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) $(TARGETS)
	cp 0install.ml "$(OCAML_BUILDDIR)/"
	if [ "$(OS)" = "Windows_NT" ];then make ocaml_windows; else make ocaml_posix; fi

# For static Windows version, we also need the runenv.native helper.
# Also, we need an XML manifest, or Windows 7 won't run it because it has "install" in its name.
ocaml_windows:
	cp ${OCAML_BUILDDIR}/static_0install.$(TYPE) ${OCAML_BUILDDIR}/0install.exe
	cp ${OCAML_BUILDDIR}/runenv.native ${OCAML_BUILDDIR}/0install-runenv.exe
	${MS_SDK}/mt.exe -nologo -manifest 0install.exe.manifest -outputresource:"${OCAML_BUILDDIR}/0install.exe;#1"
	${MS_SDK}/mt.exe -nologo -manifest 0install.exe.manifest -outputresource:"${OCAML_BUILDDIR}/0install-runenv.exe;#1"

ocaml_posix:
	cp ${OCAML_BUILDDIR}/static_0install.$(TYPE) ${OCAML_BUILDDIR}/0install
	[ -L 0install ] || ln -s ../build/ocaml/0install 0install
	@# so Vim can find the type annotations:
	[ -L _build -o -e _build ] || ln -s ${OCAML_BUILDDIR} _build

doc:
	ocp-pack -o support.ml.tmp support/logging.ml support/common.ml support/utils.ml support/basedir.ml support/qdom.ml support/system.ml
	echo '(** General support code; not 0install-specific *)' > support.ml
	cat support.ml.tmp >> support.ml
	rm support.ml.tmp
	$(OCAMLBUILD) 0install.docdir/index.html
	rm support.ml

# Note: you have to enable coverage in the _tags file too and delete the windows block from windows_api.ml
# Results turn up in the "html" directory after running the unit-tests.
coverage:
	rm -f tests/bisect*.out
	make test
	ocaml-bisect-report -I "${OCAML_BUILDDIR}" -html html "tests/bisect0001.out"

clean:
	$(OCAMLBUILD) -clean

tags:
	ctags *.ml support/*.ml
