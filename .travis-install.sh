#!/bin/bash
# Install OCaml and OPAM PPAs
case "$OCAML_VERSION" in
  4.01.0) ppa=avsm/ocaml41+opam12 ;;
  4.02.0) ppa=avsm/ocaml42+opam12 ;;
  *) echo Unknown $OCAML_VERSION; exit 1 ;;
esac

echo "yes" | sudo add-apt-repository ppa:$ppa
sudo apt-get update -qq
sudo apt-get install -qq ocaml ocaml-native-compilers camlp4-extra opam time libgmp-dev libgtk2.0-dev libcurl4-openssl-dev

echo OCaml version
ocaml -version

export OPAMYES=1

opam init git://github.com/ocaml/opam-repository
opam install yojson xmlm ounit react lwt extlib ocurl obus lablgtk sha
eval `opam config env`
