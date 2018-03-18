#!/bin/bash
set -eux
# Install OCaml and OPAM PPAs
install_on_ubuntu () {
  sudo apt-get install -qq time libgtk2.0-dev libcurl4-openssl-dev python-gobject-2
}

install_on_osx () {
  curl -OL "http://xquartz.macosforge.org/downloads/SL/XQuartz-2.7.6.dmg"
  sudo hdiutil attach XQuartz-2.7.6.dmg
  sudo installer -verbose -pkg /Volumes/XQuartz-2.7.6/XQuartz.pkg -target /
  brew update &> /dev/null
  brew unlink python	# Python 3 conflicts with Python 2's /usr/local/bin/2to3-2 file
  brew upgrade gnupg
  brew install gtk+ pygobject
  export PKG_CONFIG_PATH=/usr/local/Library/Homebrew/os/mac/pkgconfig/10.9:/usr/lib/pkgconfig
}

case $TRAVIS_OS_NAME in
  linux)
         install_on_ubuntu ;;
  osx)
         install_on_osx ;;
  *) echo "Unknown OS $TRAVIS_OS_NAME";
     exit 1 ;;
esac

# (downloaded by Travis install step)
bash -e ./.travis-opam.sh
