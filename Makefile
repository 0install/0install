all:
	pychecker *.py

test:
	./injector-gui/injector-gui Tests/edit.xml AppRun
