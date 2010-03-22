#!/usr/bin/env python
from basetest import BaseTest
import sys, os
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import model, arch, qdom
from zeroinstall.injector.namespaces import XMLNS_IFACE

#from zeroinstall.injector.origsolver import DefaultSolver as Solver
from zeroinstall.injector.pbsolver import PBSolver as Solver
#from zeroinstall.injector.sgsolver import DefaultSolver as Solver

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
			impl = child(root, 'implementation', {
				'id': str(i),
				'version': str(version.n),
			})
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
	
	def get_prog(self, prog):
		if not prog in self.progs:
			self.progs[prog] = Program(prog)
		return self.progs[prog]

	def get_interface(self, uri):
		if uri not in self.interfaces:
			iface = model.Interface(uri)
			iface._main_feed = self.progs[uri.rsplit('/', 1)[1]].build_feed()
			self.interfaces[uri] = iface
		return self.interfaces[uri]

def assertSelection(expected, repo):
	cache = TestCache()

	expected = [tuple(e.strip().split('-')) for e in expected.split(",")]

	for line in repo.split('\n'):
		line = line.strip()
		if not line: continue
		if ':' in line:
			prog, versions = line.split(':')
			prog = prog.strip()
			for v in versions.split():
				cache.get_prog(prog).get_version(v)
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
	s = Solver(model.network_offline, cache, stores)
	s.solve(root, arch.get_architecture('Linux', 'x86_64'))
	assert s.ready

	actual = []
	for iface, impl in s.selections.iteritems():
		actual.append(((iface.uri.rsplit('/', 1)[1]), impl.get_version()))

	expected.sort()
	actual.sort()
	if expected != actual:
		raise Exception("Solve failed:\nExpected: %s\n  Actual: %s" % (expected, actual))

class TestSAT(BaseTest):
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

suite = unittest.makeSuite(TestSAT)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
