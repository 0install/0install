#!/usr/bin/env python
from __future__ import print_function

from basetest import BaseTest, BytesIO
import sys, os, locale
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import arch, model, qdom
from zeroinstall.injector.requirements import Requirements

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

mydir = os.path.dirname(os.path.abspath(__file__))
command_dep = os.path.join(mydir, 'command-dep.xml')

class TestSolver(BaseTest):
		
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
