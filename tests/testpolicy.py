#!/usr/bin/env python
from basetest import BaseTest
import sys
import unittest

sys.path.insert(0, '..')
from zeroinstall.support import tasks
from zeroinstall.injector import model
from zeroinstall.injector.policy import Policy

import warnings
import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

class TestPolicy(BaseTest):
	def testSource(self):
		iface_cache = self.config.iface_cache

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		self.import_feed(foo.uri, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		self.import_feed(foo_src.uri, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

		self.config.freshness = 0
		self.config.network_use = model.network_full
		p = Policy('http://foo/Binary.xml', config = self.config)
		tasks.wait_for_blocker(p.solve_with_downloads())
		assert p.implementation[foo].id == 'sha1=123'

		# Now ask for source instead
		p.requirements.source = True
		p.requirements.command = 'compile'
		tasks.wait_for_blocker(p.solve_with_downloads())
		assert p.solver.ready, p.solver.get_failure_reason()
		assert p.implementation[foo].id == 'sha1=234'		# The source
		assert p.implementation[compiler].id == 'sha1=345'	# A binary needed to compile it

if __name__ == '__main__':
	unittest.main()
