#!/usr/bin/env python2.4
from basetest import BaseTest
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import solver, reader, arch, model
from zeroinstall.injector.iface_cache import iface_cache

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

class TestSolver(BaseTest):
	def testSimple(self):
		s = solver.DefaultSolver(model.network_full)

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		reader.update(foo, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		reader.update(foo_src, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		reader.update(compiler, 'Compiler.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		ready, selections, feeds_used = s.solve('http://foo/Binary.xml', iface_cache, binary_arch)
				
		assert ready
		assert feeds_used == set([foo.uri]), feeds_used
		assert selections.selections[foo.uri].id == 'sha1=123'

		# Now ask for source instead
		ready, selections, feeds_used = s.solve('http://foo/Binary.xml', iface_cache,
				arch.SourceArchitecture(binary_arch))
		assert ready
		assert feeds_used == set([foo.uri, foo_src.uri, compiler.uri]), feeds_used
		assert selections.selections[foo.uri].id == 'sha1=234'		# The source
		assert selections.selections[compiler.uri].id == 'sha1=345'	# A binary needed to compile it

suite = unittest.makeSuite(TestSolver)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
