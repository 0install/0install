BUILDDIR=_build
TYPE=native
DEBUG=-cflags -g
OCAMLBUILD=ocamlbuild ${DEBUG} -use-ocamlfind -build-dir "${BUILDDIR}"
ifeq ($(OS), Windows_NT)
  OCAMLBUILDFLAGS = -lflag -cclib -lflag -lshell32
endif

.PHONY: all ocaml doc clean tags test

all: test

test: ocaml
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) tests/test.$(TYPE)
	(cd tests && ../_build/tests/test.$(TYPE))

ocaml: 
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) main.$(TYPE)
	if [ "$(OS)" = "Windows_NT" ];then make ocaml_windows; else make ocaml_posix; fi

ocaml_windows:
	cp _build/main.$(TYPE) _build/0install.exe
	cp 0install.exe.manifest _build/
	$(OCAMLBUILD) $(OCAMLBUILDFLAGS) runenv.$(TYPE)
	cp _build/runenv.$(TYPE) _build/0install-runenv.exe

ocaml_posix:
	cp _build/main.$(TYPE) _build/0install
	[ -f 0install ] || ln -s _build/0install 0install

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
