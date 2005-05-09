#!/usr/bin/env python2.3
import unittest, os, sys
import coverage
coverage.erase()
coverage.start()

my_dir = os.path.dirname(sys.argv[0])
if not my_dir:
	my_dir=os.getcwd()
print "Running from", my_dir

sys.argv.append('-v')

suite_names = [f[:-3] for f in os.listdir(my_dir)
		if f.startswith('test') and f.endswith('.py')]
suite_names.remove('testall')
suite_names.sort()

alltests = unittest.TestSuite()

for name in suite_names:
	m = __import__(name, globals(), locals(), [])
	alltests.addTest(m.suite)

unittest.TextTestRunner(verbosity=2).run(alltests)

coverage.stop()

d = '../zeroinstall/injector'
all_sources = [os.path.join(d, x) for x in os.listdir(d)
		if x.endswith('.py')] + ['../0launch']
coverage.report(all_sources)
