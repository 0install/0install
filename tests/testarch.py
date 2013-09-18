#!/usr/bin/env python
from basetest import BaseTest
import sys
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import arch
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

	def testArch(self):
		host_arch = arch.get_host_architecture()
		host_arch2 = arch.get_architecture(None, None)
		self.assertEqual(host_arch.os_ranks, host_arch2.os_ranks)
		self.assertEqual(host_arch.machine_ranks, host_arch2.machine_ranks)

		other = arch.get_architecture('FooBar', 'i486')
		self.assertEqual(3, len(other.os_ranks))

		assert 'POSIX' in other.os_ranks
		assert 'FooBar' in other.os_ranks
		assert None in other.os_ranks
		assert 'i486' in other.machine_ranks
		assert 'ppc' not in other.machine_ranks

		win = arch.get_architecture('Windows', 'i486')
		self.assertEqual(2, len(win.os_ranks))
		assert 'POSIX' not in win.os_ranks

if __name__ == '__main__':
	unittest.main()
