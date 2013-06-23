BUILDDIR=_build
OCAMLBUILD=ocamlbuild -use-ocamlfind -build-dir "${BUILDDIR}"

.PHONY: all ocaml byte doc clean

all: ocaml

ocaml: 
	$(OCAMLBUILD) main.native

byte:
	$(OCAMLBUILD) main.byte

doc:
	$(OCAMLBUILD) 0install.docdir/index.html

clean:
	$(OCAMLBUILD) -clean
