all:
	pychecker *.py

test:
	./injector/injector-auto injector-gui.xml injector-gui Tests/edit.xml AppRun
