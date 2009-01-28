

PYTHON=python

PY = $(shell find zeroinstall -name '*.py')
GLADE = $(shell find zeroinstall -name '*.glade' | sed -e 's/.glade/&.h/')

all:
	$(PYTHON) setup.py build

install:
	$(PYTHON) setup.py install

%.glade.h: %.glade
	intltool-extract --type=gettext/glade --update "$<"

locale/zero-install.pot: $(PY) $(GLADE)
	xgettext --language=Python --output=$@ --keyword=_ --keyword=N_ $^

clean:
	$(PYTHON) setup.py clean

.PHONY: all install clean
