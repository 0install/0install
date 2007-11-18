#!/bin/sh
set -e -x
for version in 2.4 2.5; do
  python$version ./testall.py
done
