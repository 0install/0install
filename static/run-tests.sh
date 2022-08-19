#!/bin/bash
set -eu
cd /tmp
tar xf /mnt/dist.tgz
/tmp/dist/install.sh local
/usr/local/bin/0install --version
echo -n "Checking that GTK plugin loads... "
env DISPLAY=:0 0install config -g 2>&1 | grep -q 'ml_gtk_init: initialization failed'
echo OK
echo "Checking installation of 0test..."
0install add 0test https://apps.0install.net/0install/0test.xml
0test --version | grep '0test (zero-install)'
echo "All tests passed!"
