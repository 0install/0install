# When building with 0compile, these will get overridden.
SRCDIR = $(abspath .)
DISTDIR = $(abspath dist)

# Using PROFILE=dev makes warnings fatal and makes the build faster by doing fewer optimisations
PROFILE ?= release

# There are several things you might want to do:
#
# 1. a traditional install (e.g. under /usr/local or ~)
# 2. build a library for other 0install tools (e.g. 0compile)
# 3. for testing, in place (during development)
#
# New users and distribution packagers will want to do (1).
#
# When you do a plain "make", $DISTDIR ends up with a complete distribution
# suitable for publishing or registering with 0install. $DISTDIR contains:
#
# - The compiled binaries
# - A 0install binary feed, which can be registered with "0install add"
#
# To install as a normal package:	make && sudo make install
# To test without installing:     	make && ./dist/bin/0install
# To use as a library with other tools: 0compile build && 0compile register
# To publish a release on 0install.net: use 0release

default: all test

%.html: %.md
	redcarpet $< > $@ || (rm -f $@; false)

clean:
	dune clean --root=. --profile=${PROFILE}
	rm -rf build dist

DOCS = README.md COPYING
MANPAGES = 0launch.1 0store-secure-add.1 0store.1 0desktop.1 0install.1

OS = $(shell uname -s)
MACHINE = $(shell uname -m)
VERSION = $(shell sed -n 's/let version = "\(.*\)"/\1/p' ${SRCDIR}/ocaml/zeroinstall/about.ml)

all:
	dune build --root=. --profile=${PROFILE} @install
	install -d "${DISTDIR}"
	install -d "${DISTDIR}/files"
	install -d "${DISTDIR}/files/gui_gtk"
	install -d "${DISTDIR}/files/share"
	(cd "${SRCDIR}" && cp ${DOCS} "${DISTDIR}/")
	-install _build/install/default/lib/0install/gui_gtk.cma "${DISTDIR}/files/gui_gtk/"
	-install _build/install/default/lib/0install/gui_gtk.cmxs "${DISTDIR}/files/gui_gtk/"
	install _build/install/default/bin/0install "${DISTDIR}/files/0install"
	ln -f "${DISTDIR}/files/0install" "${DISTDIR}/files/0launch"
	ln -f "${DISTDIR}/files/0install" "${DISTDIR}/files/0store"
	ln -f "${DISTDIR}/files/0install" "${DISTDIR}/files/0store-secure-add"
	ln -f "${DISTDIR}/files/0install" "${DISTDIR}/files/0desktop"
	ln -f "${DISTDIR}/files/0install" "${DISTDIR}/files/0alias"
	(cd "${SRCDIR}/ocaml" && cp ${MANPAGES} "${DISTDIR}/files")
	install "${SRCDIR}/install.sh.src" "${DISTDIR}/install.sh"
	(cd "${SRCDIR}" && cp -r share/0install.net share/applications share/metainfo share/bash-completion share/fish share/icons share/zsh "${DISTDIR}/files/share/")
	install -d "${DISTDIR}/0install"
	[ -f "${DISTDIR}/0install/build-environment.xml" ] || sed 's/@ARCH@/${OS}-${MACHINE}/;s/@VERSION@/${VERSION}/' "${SRCDIR}/binary-feed.xml.in" > "${DISTDIR}/0install/feed.xml"

test:
	dune runtest --root=. --profile=${PROFILE}

doc:
	dune build --root=. --profile=${PROFILE} @doc

install: install_local

install_home:
	(cd "${DISTDIR}" && ./install.sh home)

install_system:
	(cd "${DISTDIR}" && ./install.sh system)

install_local:
	(cd "${DISTDIR}" && ./install.sh local)

.PHONY: all install test

.PHONY: clean default
