#!/bin/sh
set -e -x
for version in 2.5 "2.6 -3"; do
  python$version ./testall.py
done
