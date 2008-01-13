#!/usr/bin/env python2.4
from basetest import BaseTest
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.zerostore import Stores
from zeroinstall.injector import solver, reader, arch, model
from zeroinstall.injector.iface_cache import iface_cache

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

class TestSolver(BaseTest):
	def testSimple(self):
		s = solver.DefaultSolver(model.network_full, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		reader.update(foo, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		reader.update(foo_src, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		reader.update(compiler, 'Compiler.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		ready = s.solve('http://foo/Binary.xml', binary_arch)
				
		assert ready
		assert s.feeds_used == set([foo.uri]), s.feeds_used
		assert s.selections[foo].id == 'sha1=123'

		# Now ask for source instead
		ready  = s.solve('http://foo/Binary.xml',
				arch.SourceArchitecture(binary_arch))
		assert ready
		assert s.feeds_used == set([foo.uri, foo_src.uri, compiler.uri]), s.feeds_used
		assert s.selections[foo].id == 'sha1=234'		# The source
		assert s.selections[compiler].id == 'sha1=345'	# A binary needed to compile it

		assert not s.details
	
	def testDetails(self):
		s = solver.DefaultSolver(model.network_full, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		reader.update(foo, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		reader.update(foo_src, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		reader.update(compiler, 'Compiler.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.record_details = True
		ready = s.solve('http://foo/Binary.xml', arch.SourceArchitecture(binary_arch))
		assert ready

		assert len(s.details) == 2
		assert s.details[foo] == [(foo_src._main_feed.implementations['sha1=234'], None), (foo._main_feed.implementations['sha1=123'], 'Unsupported machine type')]
		assert s.details[compiler] == [(compiler._main_feed.implementations['sha1=345'], None)]
		

suite = unittest.makeSuite(TestSolver)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
