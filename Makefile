all:
	pychecker *.py

test:
	PYTHONPATH=injector ./injector-gui/injector-gui Tests/edit.xml AppRun
