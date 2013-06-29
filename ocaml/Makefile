BUILDDIR=_build
OCAMLBUILD=ocamlbuild -use-ocamlfind -build-dir "${BUILDDIR}"

.PHONY: all ocaml byte doc clean tags test

all: test

test: ocaml
	$(OCAMLBUILD) test.native
	./_build/test.native

ocaml: 
	$(OCAMLBUILD) main.native
	mv _build/main.native _build/0install

byte:
	$(OCAMLBUILD) main.byte

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
