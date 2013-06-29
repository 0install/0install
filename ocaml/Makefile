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
	$(OCAMLBUILD) 0install.docdir/index.html

clean:
	$(OCAMLBUILD) -clean

tags:
	ctags *.ml support/*.ml
