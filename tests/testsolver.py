#!/usr/bin/env python2.5
from basetest import BaseTest
import sys
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
		assert str(binary_arch).startswith("<Arch")
		s.solve('http://foo/Binary.xml', binary_arch)
				
		assert s.ready
		assert s.feeds_used == set([foo.uri]), s.feeds_used
		assert s.selections[foo].id == 'sha1=123'

		# Now ask for source instead
		s.solve('http://foo/Binary.xml',
				arch.SourceArchitecture(binary_arch))
		assert s.ready
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
		s.solve('http://foo/Binary.xml', arch.SourceArchitecture(binary_arch))
		assert s.ready

		assert len(s.details) == 2
		assert s.details[foo] == [(foo_src._main_feed.implementations['sha1=234'], None), (foo._main_feed.implementations['sha1=123'], 'Unsupported machine type')]
		assert s.details[compiler] == [(compiler._main_feed.implementations['sha1=345'], None)]

	def testRecursive(self):
		s = solver.DefaultSolver(model.network_full, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/Recursive.xml')
		reader.update(foo, 'Recursive.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.record_details = True
		s.solve('http://foo/Recursive.xml', binary_arch)
		assert s.ready

		assert len(s.details) == 1
		assert s.details[foo] == [(foo._main_feed.implementations['sha1=abc'], None)]
		
	def testMultiArch(self):
		s = solver.DefaultSolver(model.network_full, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/MultiArch.xml')
		reader.update(foo, 'MultiArch.xml')
		lib = iface_cache.get_interface('http://foo/MultiArchLib.xml')
		reader.update(lib, 'MultiArchLib.xml')

		# On an i686 system we can only use the i486 implementation

		binary_arch = arch.get_architecture('Linux', 'i686')
		s.solve('http://foo/MultiArch.xml', binary_arch)
		assert s.ready
		assert s.selections[foo].machine == 'i486'
		assert s.selections[lib].machine == 'i486'

		# On an 64 bit system we could use either, but we prefer the 64
		# bit implementation. The i486 version of the library is newer,
		# but we must pick one that is compatible with the main binary.

		binary_arch = arch.get_architecture('Linux', 'x86_64')
		s.solve('http://foo/MultiArch.xml', binary_arch)
		assert s.ready
		assert s.selections[foo].machine == 'x86_64'
		assert s.selections[lib].machine == 'x86_64'

	def testArch(self):
		host_arch = arch.get_host_architecture()
		host_arch2 = arch.get_architecture(None, None)
		self.assertEquals(host_arch.os_ranks, host_arch2.os_ranks)
		self.assertEquals(host_arch.machine_ranks, host_arch2.machine_ranks)

		other = arch.get_architecture('FooBar', 'i486')
		self.assertEquals(2, len(other.os_ranks))

		assert 'FooBar' in other.os_ranks
		assert None in other.os_ranks
		assert 'i486' in other.machine_ranks
		assert 'ppc' not in other.machine_ranks

suite = unittest.makeSuite(TestSolver)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
