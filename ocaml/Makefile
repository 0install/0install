BUILDDIR=_build

all: ocaml

ocaml: 
	 ocamlbuild -build-dir "${BUILDDIR}" -cflags "-g,-annot,-w A-4" -use-ocamlfind -pkg yojson,xmlm,unix,str main.native
	 ocamlbuild -build-dir "${BUILDDIR}" -cflags "-g,-annot,-w A" -use-ocamlfind -pkg yojson,unix runenv.native

byte:
	 ocamlbuild -build-dir "${BUILDDIR}" -cflags -g -use-ocamlfind -pkg xmlm,unix,str main.d.byte

doc:
	ocamlbuild -build-dir "${BUILDDIR}" -use-ocamlfind -pkg yojson,xmlm,unix,str 0install.docdir/index.html
