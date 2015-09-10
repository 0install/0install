#!/bin/bash -eux
# Install OCaml and OPAM PPAs
install_on_ubuntu () {
  case "$OCAML_VERSION" in
    4.01.0) ppa=avsm/ocaml41+opam12 ;;
    4.02.0) ppa=avsm/ocaml42+opam12 ;;
    *) echo Unknown $OCAML_VERSION; exit 1 ;;
  esac

  echo "yes" | sudo add-apt-repository ppa:$ppa
  sudo apt-get update -qq
  sudo apt-get install -qq ocaml ocaml-native-compilers camlp4-extra opam time libgmp-dev libgtk2.0-dev libcurl4-openssl-dev python-gobject-2
}

install_on_osx () {
  curl -OL "http://xquartz.macosforge.org/downloads/SL/XQuartz-2.7.6.dmg"
  sudo hdiutil attach XQuartz-2.7.6.dmg
  sudo installer -verbose -pkg /Volumes/XQuartz-2.7.6/XQuartz.pkg -target /
  brew update &> /dev/null
  brew install ocaml opam pkg-config gettext gnupg gtk+ pygobject
  brew link gettext --force
}

case $TRAVIS_OS_NAME in
  linux)
	  OPAM_EXTRA=obus;
	  install_on_ubuntu ;;
  osx)
	  OPAM_EXTRA=;
	  install_on_osx ;;
  *) echo "Unknown OS $TRAVIS_OS_NAME";
     exit 1 ;;
esac

echo OCaml version
ocaml -version

export OPAMYES=1

opam init git://github.com/ocaml/opam-repository
opam install yojson xmlm ounit react lwt extlib ocurl $OPAM_EXTRA lablgtk sha
eval `opam config env`
