OCAML_BUILDDIR=../build/ocaml
TYPE=native
DEBUG=-cflags -g
OCAMLBUILD=ocamlbuild ${DEBUG} -use-ocamlfind -build-dir "${OCAML_BUILDDIR}"
ifeq ($(OS), Windows_NT)
  OCAMLBUILDFLAGS = -lflag -cclib -lflag -lshell32
endif

.PHONY: all ocaml doc clean tags test

all: ocaml

test: all
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) tests/test.$(TYPE)
	(cd tests && ../${OCAML_BUILDDIR}/tests/test.$(TYPE))

ocaml: 
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) main.$(TYPE)
	if [ "$(OS)" = "Windows_NT" ];then make ocaml_windows; else make ocaml_posix; fi

ocaml_windows:
	cp ${OCAML_BUILDDIR}/main.$(TYPE) ${OCAML_BUILDDIR}/0install.exe
	cp 0install.exe.manifest ${OCAML_BUILDDIR}/
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) runenv.$(TYPE)
	cp ${OCAML_BUILDDIR}/runenv.$(TYPE) ${OCAML_BUILDDIR}/0install-runenv.exe

ocaml_posix:
	cp ${OCAML_BUILDDIR}/main.$(TYPE) ${OCAML_BUILDDIR}/0install
	[ -L 0install ] || ln -s ../build/ocaml/0install 0install
	@# so Vim can find the type annotations:
	[ -L _build ] || ln -s ${OCAML_BUILDDIR} _build

doc:
	ocp-pack -o support.ml.tmp support/logging.ml support/common.ml support/utils.ml support/basedir.ml support/qdom.ml support/system.ml
	echo '(** General support code; not 0install-specific *)' > support.ml
	cat support.ml.tmp >> support.ml
	rm support.ml.tmp
	$(OCAMLBUILD) 0install.docdir/index.html
	rm support.ml

clean:
	$(OCAMLBUILD) -clean

tags:
	ctags *.ml support/*.ml
