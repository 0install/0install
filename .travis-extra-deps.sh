#!/bin/bash
if [ "$STATIC_DIST" == true ]; then
  set -eux
  make static-test
else
  set -eux

  # Install OCaml and OPAM PPAs
  install_on_ubuntu () {
    sudo apt-get install -qq python3
  }

  install_on_osx () {
    # Disable sandboxing on OS X; it prevents the unit-tests from working.
    cat > ~/.opamrc << EOF
  wrap-build-commands: []
  wrap-install-commands: []
  wrap-remove-commands: []
  required-tools: []
EOF
    brew update &> /dev/null
    brew unlink python@2 # Python 3 conflicts with Python 2's /usr/local/bin/2to3-2 file
    brew upgrade gnupg wget
    brew install gtk+3
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
fi
