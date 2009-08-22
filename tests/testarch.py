#!/usr/bin/env python2.5
from basetest import BaseTest, empty_feed
import sys, os
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector.arch import get_architecture

class TestArch(BaseTest):

	def setUp(self):
		BaseTest.setUp(self)

	def tearDown(self):
		BaseTest.tearDown(self)

	def testDefault(self):
		arch = get_architecture(None, None)
		assert arch

	def testOs(self):
		arch = get_architecture('MacOSX', 'ppc')
		assert ('Darwin' in arch.os_ranks)

	def testMachine(self):
		arch = get_architecture('Linux', 'i686')
		assert ('i386' in arch.machine_ranks)

suite = unittest.makeSuite(TestArch)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
