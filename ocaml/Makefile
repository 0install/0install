BUILDDIR=_build
OCAMLBUILD=ocamlbuild -use-ocamlfind -build-dir "${BUILDDIR}"

.PHONY: all ocaml byte doc clean tags

all: test

test: ocaml
	$(OCAMLBUILD) test.native
	./_build/test.native

ocaml: 
	$(OCAMLBUILD) main.native

byte:
	$(OCAMLBUILD) main.byte

doc:
	$(OCAMLBUILD) -I support 0install.docdir/index.html

clean:
	$(OCAMLBUILD) -clean

tags:
	ctags *.ml *.mli
