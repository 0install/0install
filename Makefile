

PYTHON=python

MO = $(shell find locale -name '*.po' | sed -e 's/\.po/\.mo/')
PY = $(shell find zeroinstall -name '*.py')
GTKBUILDER = $(shell find zeroinstall -name '*.ui' | sed -e 's/\.ui/&.h/')
SH = zeroinstall/zerostore/_unlzma

all: translations
	$(PYTHON) setup.py build

translations: $(MO)

install: all
	$(PYTHON) setup.py install

%.mo: %.po
	msgfmt -o "$@" "$<"

%.ui.h: %.ui
	intltool-extract --type=gettext/glade --update "$<"

locale/zero-install.pot: $(PY) $(GTKBUILDER) $(SH)
	xgettext --language=Python --output=$@ --keyword=N_ $(PY) $(GTKBUILDER)
	xgettext --language=Shell -j --output=$@ $(SH)

update-po: locale/zero-install.pot
	@for po in locale/*/LC_MESSAGES/zero-install.po; do \
	    echo -e "Merge: $$po: \c"; \
	    msgmerge -v -U $$po locale/zero-install.pot; \
	done

check-po:
	@for po in locale/*/LC_MESSAGES/zero-install.po; do \
	    echo -e "Check: $$po: \c"; \
	    msgfmt -o /dev/null --statistics -v -c $$po; \
	done
clean:
	$(PYTHON) setup.py clean

.PHONY: all install update-po check-po clean
