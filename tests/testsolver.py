#!/usr/bin/env python
from basetest import BaseTest
import sys, os, locale
import ConfigParser
import unittest

sys.path.insert(0, '..')
from zeroinstall.zerostore import Stores
from zeroinstall.injector import solver, reader, arch, model
from zeroinstall.injector.iface_cache import iface_cache

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

test_config = ConfigParser.ConfigParser()
test_config.add_section('global')
test_config.set('global', 'help_with_testing', 'False')
test_config.set('global', 'freshness', str(60 * 60 * 24 * 30))	# One month
test_config.set('global', 'network_use', 'full')

class TestSolver(BaseTest):
	def testSimple(self):
		s = solver.DefaultSolver(test_config, iface_cache, Stores())

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
				arch.SourceArchitecture(binary_arch),
				command_name = 'compile')
		assert s.ready, s.get_failure_reason()
		assert s.feeds_used == set([foo.uri, foo_src.uri, compiler.uri]), s.feeds_used
		assert s.selections[foo].id == 'sha1=234'		# The source
		assert s.selections[compiler].id == 'sha1=345'	# A binary needed to compile it

		assert not s.details
	
	def testDetails(self):
		s = solver.DefaultSolver(test_config, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		reader.update(foo, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		reader.update(foo_src, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		reader.update(compiler, 'Compiler.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.record_details = True
		s.solve('http://foo/Binary.xml', arch.SourceArchitecture(binary_arch), command_name = 'compile')
		assert s.ready, s.get_failure_reason()

		foo_src_impls = iface_cache.get_feed(foo_src.uri).implementations
		foo_impls = iface_cache.get_feed(foo.uri).implementations
		compiler_impls = iface_cache.get_feed(compiler.uri).implementations

		assert len(s.details) == 2
		self.assertEquals([(foo_src_impls['sha1=234'], None),
				   (foo_impls['sha1=123'], 'Unsupported machine type')],
				   sorted(s.details[foo]))
		assert s.details[compiler] == [(compiler_impls['sha1=345'], None)]

	def testRecursive(self):
		s = solver.DefaultSolver(test_config, iface_cache, Stores())

		foo = iface_cache.get_interface('http://foo/Recursive.xml')
		reader.update(foo, 'Recursive.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.record_details = True
		s.solve('http://foo/Recursive.xml', binary_arch)
		assert s.ready

		foo_impls = iface_cache.get_feed(foo.uri).implementations

		assert len(s.details) == 1
		assert s.details[foo] == [(foo_impls['sha1=abc'], None)]
		
	def testMultiArch(self):
		s = solver.DefaultSolver(test_config, iface_cache, Stores())

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
	
	def testRanking(self):
		s = solver.DefaultSolver(test_config, iface_cache, Stores())
		ranking = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'Ranking.xml')
		iface = iface_cache.get_interface(ranking)

		binary_arch = arch.get_architecture('Linux', 'x86_64')
		selected = []
		while True:
			s.solve(ranking, binary_arch)
			if not s.ready:
				break
			impl = s.selections[iface]
			selected.append(impl.get_version() + ' ' + impl.arch)
			impl.arch = 'Foo-odd'		# prevent reselection
		self.assertEquals([
			'0.2 Linux-i386',	# poor arch, but newest version
			'0.1 Linux-x86_64',	# 64-bit is best match for host arch
			'0.1 Linux-i686', '0.1 Linux-i586', '0.1 Linux-i486'],	# ordering of x86 versions
			selected)

	def testLangs(self):
		try:
			locale.setlocale(locale.LC_ALL, 'en_US.UTF-8')

			s = solver.DefaultSolver(test_config, iface_cache, Stores())
			iface = iface_cache.get_interface('http://foo/Langs.xml')
			reader.update(iface, 'Langs.xml')

			# 1 is the oldest, but the only one in our language
			binary_arch = arch.get_architecture(None, 'arch_1')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEquals('sha1=1', s.selections[iface].id)

			# 6 is the newest, and close enough, even though not
			# quite the right locale
			binary_arch = arch.get_architecture(None, 'arch_2')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEquals('sha1=6', s.selections[iface].id)

			# 9 is the newest, although 7 is a closer match
			binary_arch = arch.get_architecture(None, 'arch_3')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEquals('sha1=9', s.selections[iface].id)

			# 11 is the newest we understand
			binary_arch = arch.get_architecture(None, 'arch_4')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEquals('sha1=11', s.selections[iface].id)

			# 13 is the newest we understand
			binary_arch = arch.get_architecture(None, 'arch_5')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEquals('sha1=13', s.selections[iface].id)

			def check(target_arch, langs, expected):
				s.langs = langs
				binary_arch = arch.get_architecture(None, target_arch)
				s.solve('http://foo/Langs.xml', binary_arch)
				assert s.ready
				self.assertEquals(expected, s.selections[iface].id)

			# We don't understand any, so pick the newest
			check('arch_2', ['es_ES'], 'sha1=6')

			# These two have the same version number. Choose the
			# one most appropriate to our country
			check('arch_6', ['zh_CN'], 'sha1=15')
			check('arch_6', ['zh_TW'], 'sha1=16')

			# Same, but one doesn't have a country code
			check('arch_7', ['bn'], 'sha1=17')
			check('arch_7', ['bn_IN'], 'sha1=18')
		finally:
			locale.setlocale(locale.LC_ALL, '')

if __name__ == '__main__':
	unittest.main()
