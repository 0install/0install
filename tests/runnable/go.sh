#!/bin/sh
"$PROG" var "$@"
exec 0testprog path "$@"
