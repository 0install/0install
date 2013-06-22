BUILDDIR=../build
OCAML_BUILDDIR=${BUILDDIR}/ocaml

all: ocaml

ocaml: 
	 ocamlbuild -build-dir "${OCAML_BUILDDIR}" -cflags "-g,-annot,-w A-4" -use-ocamlfind -pkg yojson,xmlm,unix,str runsels.native
	 ocamlbuild -build-dir "${OCAML_BUILDDIR}" -cflags "-g,-annot,-w A" -use-ocamlfind -pkg yojson,unix runenv.native

byte:
	 ocamlbuild -build-dir "${OCAML_BUILDDIR}" -cflags -g -use-ocamlfind -pkg xmlm,unix,str runsels.d.byte

doc:
	ocamlbuild -build-dir "${OCAML_BUILDDIR}" -use-ocamlfind -pkg yojson,xmlm,unix,str 0install.docdir/index.html
