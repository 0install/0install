#!/bin/bash
echo Display: $DISPLAY
set -eux
export DISPLAY=

if [ -d 0compile ]; then
  # Already did this test
  exit 0
fi

eval `opam config env`

mkdir -p ~/.config/0install.net/injector
cat > ~/.config/0install.net/injector/trustdb.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<trusted-keys xmlns="http://zero-install.sourceforge.net/2007/injector/trust">
  <key fingerprint="DA9825AECAD089757CDABD8E07133F96CA74D8BA">
    <domain value="0install.net"/>
  </key>
  <key fingerprint="AC9B973549D819AE22BCD08D22EA111A7E4242A4">
    <domain value="repo.roscidus.com"/>
  </key>
</trusted-keys>
EOF

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
