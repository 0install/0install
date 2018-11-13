# Running make from this directory builds with the "dev" profile rather than the "release" one.
# To build and run a custom command manually, use e.g.:
#
#   dune exec 0install -- -help

default: test

all:
	make -C .. PROFILE=dev all

test:
	make -C .. PROFILE=dev test

doc:
	make -C .. PROFILE=dev doc

clean:
	make -C .. PROFILE=dev clean
