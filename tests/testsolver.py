#!/usr/bin/env python
from basetest import BaseTest
import sys, os, locale
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import solver, arch, model
from zeroinstall.injector.requirements import Requirements

import logging
logger = logging.getLogger()
#logger.setLevel(logging.DEBUG)

mydir = os.path.dirname(os.path.abspath(__file__))
command_dep = os.path.join(mydir, 'command-dep.xml')

class TestSolver(BaseTest):
	def testSimple(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		self.import_feed(foo.uri, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		self.import_feed(foo_src.uri, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

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
	
	def testCommand(self):
		s = solver.DefaultSolver(self.config)
		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.solve(command_dep, binary_arch)
		command = s.selections.selections[s.selections.interface].get_command("run")
		dep, = command.requires
		dep_impl = s.selections.selections[dep.interface]
		assert dep_impl.get_command("run").path == "test-gui"

	def testDetails(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)

		foo_binary_uri = 'http://foo/Binary.xml'
		foo = iface_cache.get_interface(foo_binary_uri)
		self.import_feed(foo_binary_uri, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		self.import_feed(foo_src.uri, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

		r = Requirements('http://foo/Binary.xml')
		r.source = True
		r.command = 'compile'

		s.record_details = True
		s.solve_for(r)
		assert s.ready, s.get_failure_reason()

		foo_bin_impls = iface_cache.get_feed(foo_binary_uri).implementations
		foo_src_impls = iface_cache.get_feed(foo_src.uri).implementations
		foo_impls = iface_cache.get_feed(foo.uri).implementations
		compiler_impls = iface_cache.get_feed(compiler.uri).implementations

		assert len(s.details) == 2
		self.assertEqual([
				(foo_src_impls['impossible'], None),
				(foo_src_impls['sha1=234'], None),
				(foo_impls['sha1=123'], 'Not source code'),
				(foo_src_impls['old'], None),
			], sorted(s.details[foo]))
		self.assertEqual([
				(compiler_impls['sha1=999'], None),
				(compiler_impls['sha1=345'], None),
				(compiler_impls['sha1=678'], None),
			], s.details[compiler])

		def justify(uri, impl, expected):
			iface = iface_cache.get_interface(uri)
			e = s.justify_decision(r, iface, impl)
			self.assertEqual(expected, e)

		justify(foo_binary_uri, foo_bin_impls["sha1=123"],
				'Binary 1.0 cannot be used (regardless of other components): Not source code')
		justify(foo_binary_uri, foo_src_impls["sha1=234"],
				'Binary 1.0 was selected as the preferred version.')
		justify(foo_binary_uri, foo_src_impls["old"],
				'Binary 0.1 is ranked lower than 1.0: newer versions are preferred')
		justify(foo_binary_uri, foo_src_impls["impossible"],
				'''There is no possible selection using Binary 3.\nCan't find all required implementations:\n- <Interface http://foo/Binary.xml> -> impossible\n- <Interface http://foo/Compiler.xml> -> None''')
		justify(compiler.uri, compiler_impls["sha1=999"],
				'''Compiler 5 is selectable, but using it would produce a less optimal solution overall.\n\nThe changes would be:\n\nhttp://foo/Binary.xml: 1.0 to 0.1''')

	def testRecursive(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)

		foo = iface_cache.get_interface('http://foo/Recursive.xml')
		self.import_feed(foo.uri, 'Recursive.xml')

		binary_arch = arch.Architecture({None: 1}, {None: 1})
		s.record_details = True
		s.solve('http://foo/Recursive.xml', binary_arch)
		assert s.ready

		foo_impls = iface_cache.get_feed(foo.uri).implementations

		assert len(s.details) == 1
		assert s.details[foo] == [(foo_impls['sha1=abc'], None)]
		
	def testMultiArch(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)

		foo = iface_cache.get_interface('http://foo/MultiArch.xml')
		self.import_feed(foo.uri, 'MultiArch.xml')
		lib = iface_cache.get_interface('http://foo/MultiArchLib.xml')
		self.import_feed(lib.uri, 'MultiArchLib.xml')

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
	
	def testArchFor(self):
		s = solver.DefaultSolver(self.config)
		r = Requirements('http://foo/Binary.xml')

		r.cpu = 'i386'
		bin_arch = s.get_arch_for(r)
		self.assertEqual({'i386': 0, None: 1}, bin_arch.machine_ranks)

		r.source = True
		src_arch = s.get_arch_for(r)
		self.assertEqual({'src': 1}, src_arch.machine_ranks)

		child = self.config.iface_cache.get_interface('http://foo/Dep.xml')
		arch = s.get_arch_for(r, child)
		self.assertEqual(arch.machine_ranks, bin_arch.machine_ranks)

		child = self.config.iface_cache.get_interface(r.interface_uri)
		arch = s.get_arch_for(r, child)
		self.assertEqual(arch.machine_ranks, src_arch.machine_ranks)

	def testRanking(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)
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
		self.assertEqual([
			'0.2 Linux-i386',	# poor arch, but newest version
			'0.1 Linux-x86_64',	# 64-bit is best match for host arch
			'0.1 Linux-i686', '0.1 Linux-i586', '0.1 Linux-i486'],	# ordering of x86 versions
			selected)

	def testRestricts(self):
		iface_cache = self.config.iface_cache
		s = solver.DefaultSolver(self.config)
		uri = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'Conflicts.xml')
		versions = os.path.join(os.path.abspath(os.path.dirname(__file__)), 'Versions.xml')
		iface = iface_cache.get_interface(uri)

		r = Requirements(uri)

		# Selects 0.2 as the highest version, applying the restriction to versions < 4.
		s.solve_for(r)
		assert s.ready
		self.assertEqual("0.2", s.selections.selections[uri].version)
		self.assertEqual("3", s.selections.selections[versions].version)

		s.extra_restrictions[iface] = [model.VersionRestriction(model.parse_version('0.1'))]
		s.solve_for(r)
		assert s.ready
		self.assertEqual("0.1", s.selections.selections[uri].version)
		self.assertEqual(None, s.selections.selections.get(versions, None))

		s.extra_restrictions[iface] = [model.VersionRestriction(model.parse_version('0.3'))]
		s.solve_for(r)
		assert not s.ready

	def testLangs(self):
		iface_cache = self.config.iface_cache
		try:
			locale.setlocale(locale.LC_ALL, 'en_US.UTF-8')

			s = solver.DefaultSolver(self.config)
			iface = iface_cache.get_interface('http://foo/Langs.xml')
			self.import_feed(iface.uri, 'Langs.xml')

			# 1 is the oldest, but the only one in our language
			binary_arch = arch.get_architecture(None, 'arch_1')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEqual('sha1=1', s.selections[iface].id)

			# 6 is the newest, and close enough, even though not
			# quite the right locale
			binary_arch = arch.get_architecture(None, 'arch_2')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEqual('sha1=6', s.selections[iface].id)

			# 9 is the newest, although 7 is a closer match
			binary_arch = arch.get_architecture(None, 'arch_3')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEqual('sha1=9', s.selections[iface].id)

			# 11 is the newest we understand
			binary_arch = arch.get_architecture(None, 'arch_4')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEqual('sha1=11', s.selections[iface].id)

			# 13 is the newest we understand
			binary_arch = arch.get_architecture(None, 'arch_5')
			s.solve('http://foo/Langs.xml', binary_arch)
			assert s.ready
			self.assertEqual('sha1=13', s.selections[iface].id)

			def check(target_arch, langs, expected):
				s.langs = langs
				binary_arch = arch.get_architecture(None, target_arch)
				s.solve('http://foo/Langs.xml', binary_arch)
				assert s.ready
				self.assertEqual(expected, s.selections[iface].id)

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

	def testDecideBug(self):
		s = solver.DefaultSolver(self.config)
		watch_xml = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'watchdog.xml')
		s.solve(watch_xml, arch.get_architecture(None, None), command_name = 'test')

	def testRecommendBug(self):
		s = solver.DefaultSolver(self.config)
		optional_missing_xml = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'OptionalMissing.xml')
		s.solve(optional_missing_xml, arch.get_architecture(None, None), command_name = None)

if __name__ == '__main__':
	unittest.main()
