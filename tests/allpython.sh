#!/bin/sh
set -e -x
for version in 2.5 "2.6" "2.7 -3"; do
  python$version -tt ./testall.py
done
