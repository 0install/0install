# When building with 0compile, these will get overridden.
# The defaults are the same as when building with 0compile in-place (e.g.
# in a Git checkout), so you don't need 0compile to build 0install, which
# would create a bootstapping problem.
SRCDIR = $(abspath .)
DISTDIR = $(abspath dist)
BUILDDIR = $(abspath build)

# Default to /usr because Python doesn't look in /usr/local by default on all systems.
PREFIX = /usr

GTKBUILDER = $(shell cd ${SRCDIR} && find zeroinstall -name '*.ui' | sort | sed -e 's/\.ui/&.h/')
SH = zeroinstall/zerostore/_unlzma
PY = $(shell cd ${SRCDIR} && find zeroinstall -name '*.py' | sort)

# There are several things you might want to do:
#
# 1. a traditional install (e.g. under /usr/local or ~)
# 2. build a library for other 0install tools (e.g. 0compile)
# 3. for testing, in place (during development)
#
# New users and distribution packagers will want to do (1).
#
# When you do a plain "make":
#
# a) $DISTDIR ends up with a complete distribution suitable for publishing or
#    registering with 0install. $DISTDIR contains:
#    - Python source code
#    - Cross-platform OCaml bytecode
#    - A 0install binary feed, which can be registered with "0install add"
#
# b) A native "0install" executable is created in $BUILDDIR, but is not copied
#    to $DISTDIR (since it's not portable).
#
# To install as a normal package:	make && sudo make install
# To test without installing:     	make && ./dist/bin/0install
# To use as a library with other tools: 0compile build && 0compile register
# To publish a release on 0install.net: use 0release
# To make a generic build/static_dist:  make static_dist
#
# Running plain "make" does most of the same things that "0compile build" would do,
# except that it doesn't generate/update the binary feed (dist/0install/feed.xml).

default: all

# Ubuntu's make requires this to come before the %:: default rule.
%.ui.h: %.ui
	intltool-extract --type=gettext/glade --update "$<"

# Make needs to run from the build directory, but people always want to run it from
# the source directory. This rule matches all targets not defined here (i.e. those
# which operate on the build directory) and runs make again from the build directory,
# with Makefile.build.
%::
	[ -d "${BUILDDIR}" ] || mkdir "${BUILDDIR}"
	[ -d "${DISTDIR}" ] || mkdir "${DISTDIR}"
	make -C "${BUILDDIR}" -f "${SRCDIR}/Makefile.build" "$@" SRCDIR="${SRCDIR}" BUILDDIR="${BUILDDIR}" DISTDIR="${DISTDIR}" PREFIX="${PREFIX}"

share/locale/zero-install.pot: $(PY) $(GTKBUILDER) $(SH)
	xgettext --sort-by-file --language=Python --output=$@ --keyword=N_ $(PY) $(GTKBUILDER)
	xgettext --sort-by-file --language=Shell -j --output=$@ $(SH)

update-po: share/locale/zero-install.pot
	@for po in share/locale/*/LC_MESSAGES/zero-install.po; do \
	    echo -e "Merge: $$po: \c"; \
	    msgmerge -v -U $$po share/locale/zero-install.pot; \
	done

check-po:
	@for po in share/locale/*/LC_MESSAGES/zero-install.po; do \
	    echo -e "Check: $$po: \c"; \
	    msgfmt -o /dev/null --statistics -v -c $$po; \
	done

clean:
	rm -rf build
	rm -rf dist

.PHONY: update-po check-po clean default
