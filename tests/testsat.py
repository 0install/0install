#!/usr/bin/env python
from basetest import BaseTest
import ConfigParser
import sys, os
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import model, arch, qdom
from zeroinstall.injector.namespaces import XMLNS_IFACE

from zeroinstall.injector.solver import SATSolver as Solver
from zeroinstall.injector import sat

import logging
logger = logging.getLogger()

class Stores:
	def lookup_any(self, digests):
		return "/"

stores = Stores()

uri_prefix = 'http://localhost/tests/'

class Version:
	def __init__(self, n):
		self.n = n
		self.requires = []
		self.arch = None

	def add_requires(self, lib, min_v, max_v):
		self.requires.append((lib, min_v, max_v))

class Program:
	def __init__(self, name):
		self.name = name
		self.versions = {}

	def get_version(self, version):
		if version not in self.versions:
			self.versions[version] = Version(version)
		return self.versions[version]

	def build_feed(self):
		def child(parent, name, attrs = None):
			new = qdom.Element(XMLNS_IFACE, name, attrs or {})
			parent.childNodes.append(new)
			return new

		root = qdom.Element(XMLNS_IFACE, 'interface', {'uri' : uri_prefix + self.name})
		child(root, 'name').content = self.name
		child(root, 'summary').content = self.name

		i = 0
		for version in self.versions.values():
			attrs = {
				'id': str(i),
				'version': str(version.n),
				'main': 'dummy',
			}
			if version.arch:
				attrs['arch'] = version.arch
			impl = child(root, 'implementation', attrs)
			child(impl, 'manifest-digest', {'sha1new': '1234'})
			for lib, min_v, max_v in version.requires:
				req = child(impl, 'requires', {'interface': uri_prefix + lib})
				child(req, 'version', {
					'before': str(int(max_v) + 1),
					'not-before': min_v})
			i += 1

		feed = model.ZeroInstallFeed(root)
		feed.last_modified = 1
		return feed

class TestCache:
	def __init__(self):
		self.progs = {}
		self.interfaces = {}
		self.feeds = {}

	def get_prog(self, prog):
		if not prog in self.progs:
			self.progs[prog] = Program(prog)
		return self.progs[prog]

	def get_interface(self, uri):
		if uri not in self.interfaces:
			iface = model.Interface(uri)
			self.interfaces[uri] = iface
		return self.interfaces[uri]

	def get_feed(self, url):
		if url not in self.feeds:
			feed = self.progs[url.rsplit('/', 1)[1]].build_feed()
			self.feeds[url] = feed
		return self.feeds[url]

	def get_feed_imports(self, iface):
		return []

def assertSelection(expected, repo):
	cache = TestCache()

	expected = [tuple(e.strip().split('-')) for e in expected.split(",")]

	for line in repo.split('\n'):
		line = line.strip()
		if not line: continue
		if ':' in line:
			prog, versions = line.split(':')
			prog = prog.strip()
			if ' ' in prog:
				prog, prog_arch = prog.split()
			else:
				prog_arch = None
			for v in versions.split():
				cache.get_prog(prog).get_version(v).arch = prog_arch
		elif '=>' in line:
			prog, requires = line.split('=>')
			prog, version_range = prog.strip().split('[')
			lib, min_v, max_v = requires.split()
			assert version_range.endswith(']')
			version_range = version_range[:-1]
			if ',' in version_range:
				min_p, max_p = map(int, version_range.split(','))
				prog_versions = range(min_p, max_p + 1)
			else:
				prog_versions = [int(version_range)]
			for prog_version in prog_versions:
				cache.get_prog(prog).get_version(str(prog_version)).add_requires(lib, min_v, max_v)

	root = uri_prefix + expected[0][0]

	test_config = ConfigParser.RawConfigParser()
	test_config.add_section('global')
	test_config.set('global', 'help_with_testing', 'False')
	test_config.set('global', 'network_use', model.network_offline)

	s = Solver(test_config, cache, stores)
	s.solve(root, arch.get_architecture('Linux', 'x86_64'))

	if expected[0][1] == 'FAIL':
		assert not s.ready
	else:
		assert s.ready

		actual = []
		for iface, impl in s.selections.iteritems():
			actual.append(((iface.uri.rsplit('/', 1)[1]), impl.get_version()))

		expected.sort()
		actual.sort()
		if expected != actual:
			raise Exception("Solve failed:\nExpected: %s\n  Actual: %s" % (expected, actual))
	return s

class TestSAT(BaseTest):
	def testTrivial(self):
		assertSelection("prog-2", """
			prog: 1 2
			""")

	def testSimple(self):
		assertSelection("prog-5, liba-5", """
			prog: 1 2 3 4 5
			liba: 1 2 3 4 5
			prog[1] => liba 0 4
			prog[2] => liba 1 5
			prog[5] => liba 4 5
			""")

	def testBestImpossible(self):
		assertSelection("prog-1", """
			prog: 1 2
			liba: 1
			prog[2] => liba 3 4
			""")

	def testSlow(self):
		assertSelection("prog-1", """
			prog: 1 2 3 4 5 6 7 8 9
			liba: 1 2 3 4 5 6 7 8 9
			libb: 1 2 3 4 5 6 7 8 9
			libc: 1 2 3 4 5 6 7 8 9
			libd: 1 2 3 4 5 6 7 8 9
			libe: 1
			prog[2,9] => liba 1 9
			liba[1,9] => libb 1 9
			libb[1,9] => libc 1 9
			libc[1,9] => libd 1 9
			libd[1,9] => libe 0 0
			""")

	def testNoSolution(self):
		assertSelection("prog-FAIL", """
			prog: 1 2 3
			liba: 1
			prog[1,3] => liba 2 3
			""")

	def testBacktrackSimple(self):
		# We initially try liba-3 before learning that it
		# is incompatible and backtracking.
		# We learn that liba-3 doesn't work ever.
		assertSelection("prog-1, liba-2", """
			prog: 1
			liba: 1 2 3
			prog[1] => liba 1 2
			""")

	def testBacktrackLocal(self):
		# We initially try liba-3 before learning that it
		# is incompatible and backtracking.
		# We learn that liba-3 doesn't work with prog-1.
		assertSelection("prog-2, liba-2", """
			prog: 1 2
			liba: 1 2 3
			prog[1,2] => liba 1 2
			""")

	def testLearning(self):
		# Prog-2 depends on libb and libz, but we can't have both
		# at once. The learning means we don't have to explore every
		# possible combination of liba and libb.
		assertSelection("prog-1", """
			prog: 1 2
			liba: 1 2 3
			libb Linux-i486: 1 2 3
			libz Linux-x86_64: 1 2
			prog[2] => liba 1 3
			prog[2] => libz 1 2
			liba[1,3] => libb 1 3
			""")

	def testToplevelConflict(self):
		# We don't detect the conflict until we start solving, but the
		# conflict is top-level so we abort immediately without
		# backtracking.
		assertSelection("prog-FAIL", """
			prog Linux-i386: 1
			liba Linux-x86_64: 1
			prog[1] => liba 1 1
			""")

	def testDiamondConflict(self):
		# prog depends on liba and libb, which depend on incompatible
		# versions of libc.
		assertSelection("prog-FAIL", """
			prog: 1
			liba: 1
			libb: 1
			libc: 1 2
			prog[1] => liba 1 1
			prog[1] => libb 1 1
			liba[1] => libc 1 1
			libb[1] => libc 2 3
			""")

	def testCoverage(self):
		# Try to trigger some edge cases...

		# An at_most_one clause must be analysed for causing
		# a conflict.
		solver = sat.SATProblem()
		v1 = solver.add_variable("v1")
		v2 = solver.add_variable("v2")
		v3 = solver.add_variable("v3")
		solver.at_most_one([v1, v2])
		solver.add_clause([v1, sat.neg(v3)])
		solver.add_clause([v2, sat.neg(v3)])
		solver.add_clause([v1, v3])
		solver.run_solver(lambda: v3)

	def testFailState(self):
		# If we can't select a valid combination,
		# try to select as many as we can.
		s = assertSelection("prog-FAIL", """
			prog: 1 2
			liba: 1 2
			libb: 1 2
			libc: 5
			prog[1,2] => liba 1 2
			liba[1,2] => libb 1 2
			libb[1,2] => libc 0 0
			""")
		assert not s.ready
		selected = {}
		for iface, impl in s.selections.iteritems():
			if impl is not None: impl = impl.get_version()
			selected[iface.uri.rsplit('/', 1)[1]] = impl
		self.assertEquals({
			'prog': '2',
			'liba': '2',
			'libb': '2',
			'libc': None
		}, selected)
	
	def testWatch(self):
		solver = sat.SATProblem()

		a = solver.add_variable('a')
		b = solver.add_variable('b')
		c = solver.add_variable('c')

		# Add a clause. It starts watching the first two variables (a and b).
		# (use the internal function to avoid variable reordering)
		solver._add_clause([a, b, c], False)
		
		# b is False, so it switches to watching a and c
		solver.add_clause([sat.neg(b)])

		# Try to trigger bug.
		solver.add_clause([c])

		decisions = [a]
		solver.run_solver(lambda: decisions.pop())
		assert not decisions	# All used up

		assert solver.assigns[a].value == True

	def testOverbacktrack(self):
		# After learning that prog-3 => m0 we backtrack all the way up to the prog-3
		# assignment, unselecting liba-3, and then select it again.
		assertSelection("prog-3, liba-3, libb-3, libc-1, libz-2", """
			prog: 1 2 3
			liba: 1 2 3
			libb: 1 2 3
			libc Linux-x86_64: 2 3
			libc Linux-i486: 1
			libz Linux-i386: 1 2
			prog[2,3] => liba 1 3
			prog[2,3] => libz 1 2
			liba[1,3] => libb 1 3
			libb[1,3] => libc 1 3
			""")

if __name__ == '__main__':
	unittest.main()
