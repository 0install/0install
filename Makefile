PYTHON=$(shell which python3 || which python2 || echo python)

MO = $(shell find share/locale -name '*.po' | sort | sed -e 's/\.po/\.mo/')
PY = $(shell find zeroinstall -name '*.py' | sort)
GTKBUILDER = $(shell find zeroinstall -name '*.ui' | sort | sed -e 's/\.ui/&.h/')
SH = zeroinstall/zerostore/_unlzma

all_except_ocaml: translations
	$(PYTHON) setup.py build

translations: $(MO)

ocaml: all_except_ocaml
	make -C ocaml ocaml

install: all_except_ocaml
	$(PYTHON) setup.py install --force

%.mo: %.po
	msgfmt -o "$@" "$<"

%.ui.h: %.ui
	intltool-extract --type=gettext/glade --update "$<"

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
	$(PYTHON) setup.py clean
	if [ -d ocaml/_build ]; then make -C ocaml clean; fi

.PHONY: all install update-po check-po clean ocaml
