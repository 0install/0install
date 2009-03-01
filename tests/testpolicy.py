#!/usr/bin/env python2.5
from basetest import BaseTest
import sys
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import autopolicy, reader, model
from zeroinstall.injector.iface_cache import iface_cache

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

class TestPolicy(BaseTest):
	def testSource(self):
		foo = iface_cache.get_interface('http://foo/Binary.xml')
		reader.update(foo, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		reader.update(foo_src, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		reader.update(compiler, 'Compiler.xml')

		p = autopolicy.AutoPolicy('http://foo/Binary.xml', dry_run = True)
		p.freshness = 0
		p.network_use = model.network_full
		p.recalculate()
		assert p.implementation[foo].id == 'sha1=123'

		# Now ask for source instead
		p.src = True
		p.recalculate()
		assert p.implementation[foo].id == 'sha1=234'		# The source
		assert p.implementation[compiler].id == 'sha1=345'	# A binary needed to compile it

suite = unittest.makeSuite(TestPolicy)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
