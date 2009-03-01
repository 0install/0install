

PYTHON=python

MO = $(shell find locale -name '*.po' | sed -e 's/\.po/\.mo/')
PY = $(shell find zeroinstall -name '*.py')
GLADE = $(shell find zeroinstall -name '*.glade' | sed -e 's/\.glade/&.h/')

all: $(MO)
	$(PYTHON) setup.py build

install: all
	$(PYTHON) setup.py install

%.mo: %.po
	msgfmt -o "$@" "$<"

%.glade.h: %.glade
	intltool-extract --type=gettext/glade --update "$<"

locale/zero-install.pot: $(PY) $(GLADE)
	xgettext --language=Python --output=$@ --keyword=_ --keyword=N_ $^

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
