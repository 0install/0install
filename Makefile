all:
	pychecker *.py

test:
	./injector AppRun ../injector/edit.xml
