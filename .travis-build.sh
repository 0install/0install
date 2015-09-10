#!/bin/bash -eux
echo Display: $DISPLAY
export DISPLAY=

eval `opam config env`
make
sudo make install
0install add-feed http://0install.net/tools/0install.xml dist/0install/feed.xml
git clone https://github.com/0install/0compile.git -b use-ocaml
0install select -c 0compile/0compile.xml

# Autocompile doesn't use the new solver, so test with manual build for now
0install run -c 0compile/0compile.xml -v setup http://0install.net/tests/GNU-Hello.xml
cd GNU-Hello
0install run -c ../0compile/0compile.xml -v build

#0install run -c 0compile/0compile.xml autocompile http://0install.net/tests/GNU-Hello.xml
#0install run -c http://0install.net/tests/GNU-Hello.xml
