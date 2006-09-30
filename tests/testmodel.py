#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest
from StringIO import StringIO

sys.path.insert(0, '..')
from zeroinstall.injector import model, qdom

class TestModel(unittest.TestCase):
	def testLevels(self):
		assert model.network_offline in model.network_levels
		assert model.network_minimal in model.network_levels
		assert model.network_full in model.network_levels

	def testStabilities(self):
		assert 'insecure' in model.stability_levels
		assert 'buggy' in model.stability_levels
		assert 'developer' in model.stability_levels
		assert 'testing' in model.stability_levels
		assert 'stable' in model.stability_levels
		assert 'preferred' in model.stability_levels
		str(model.insecure)
	
	def testEscape(self):
		self.assertEquals("", model.escape(""))
		self.assertEquals("hello", model.escape("hello"))
		self.assertEquals("%20", model.escape(" "))
		self.assertEquals("file%3a%2f%2ffoo%7ebar",
				model.escape("file://foo~bar"))
		self.assertEquals("file%3a%2f%2ffoo%25bar",
				model.escape("file://foo%bar"))

	def testUnescape(self):
		self.assertEquals("", model.unescape(""))
		self.assertEquals("hello", model.unescape("hello"))
		self.assertEquals(" ", model.unescape("%20"))
		self.assertEquals("file://foo~bar",
				model.unescape("file%3a%2f%2ffoo%7ebar"))
		self.assertEquals("file://foo%bar",
				model.unescape("file%3a%2f%2ffoo%25bar"))

	def testBadInterface(self):
		try:
			model.Interface('foo')
			assert 0
		except model.SafeException:
			pass
	
	def testInterface(self):
		i = model.Interface('http://foo')
		self.assertEquals('(foo)', i.get_name())
		repr(i)

	def testMetadata(self):
		i = model.Interface('http://foo')
		e = qdom.parse(StringIO('<ns:b xmlns:ns="a" foo="bar"/>'))
		i.metadata = [e]
		assert i.get_metadata('a', 'b') == [e]
		assert i.get_metadata('b', 'b') == []
		assert i.get_metadata('a', 'a') == []
		assert e.getAttribute('foo') == 'bar'

	def testStabPolicy(self):
		i = model.Interface('http://foo')
		self.assertEquals(None, i.stability_policy)
		i.set_stability_policy(model.buggy)
		self.assertEquals(model.buggy, i.stability_policy)
	
	def testGetImpl(self):
		i = model.Interface('http://foo')
		a = i.get_impl('foo')
		b = i.get_impl('bar')
		c = i.get_impl('foo')
		assert a and b and c
		assert a is c
		assert a is not b
		assert isinstance(a, model.Implementation)
	
	def testImpl(self):
		i = model.Interface('http://foo')
		a = model.Implementation(i, 'foo')
		assert a.id == 'foo'
		assert a.size == a.version == a.user_stability == None
		assert a.arch == a.upstream_stability == None
		assert a.dependencies == {}
		assert a.download_sources == []
		assert a.get_stability() is model.testing
		a.upstream_stability = model.stable
		assert a.get_stability() is model.stable
		a.user_stability = model.buggy
		assert a.get_stability() is model.buggy
		a.version = model.parse_version('1.2.3')
		self.assertEquals('1.2.3', a.get_version())
		a.version = model.parse_version('1.2.3-rc2-post')
		self.assertEquals('1.2.3-rc2-post', a.get_version())
		assert str(a) == 'foo'

		b = model.Implementation(i, 'foo')
		b.version = [1,2,1]
		assert b > a
	
	def testDownloadSource(self):
		i = model.Interface('http://foo')
		a = model.Implementation(i, 'foo')
		a.add_download_source('ftp://foo', 1024, None)
		a.add_download_source('ftp://foo.tgz', 1025, 'foo')
		assert a.download_sources[0].url == 'ftp://foo'
		assert a.download_sources[0].size == 1024
		assert a.download_sources[0].extract == None
		assert a.interface is i
	
	def testEnvBind(self):
		a = model.EnvironmentBinding('PYTHONPATH', 'path')
		assert a.name == 'PYTHONPATH'
		assert a.insert == 'path'
		str(a)
	
	def testDep(self):
		b = model.Dependency('http://foo')
		assert not b.restrictions
		assert not b.bindings
		str(b)
	
	def testFeed(self):
		f = model.Feed('http://feed', arch = None, user_override = False)
		assert f.uri == 'http://feed'
		assert f.os == None
		assert f.machine == None
		assert f.arch == None
		assert f.user_override == False

		f = model.Feed('http://feed', arch = 'Linux-*', user_override = True)
		assert f.uri == 'http://feed'
		assert f.os == 'Linux'
		assert f.machine == None
		assert f.arch == 'Linux-*'
		assert f.user_override == True

		f = model.Feed('http://feed', arch = '*-i386', user_override = True)
		assert f.uri == 'http://feed'
		assert f.os == None
		assert f.machine == 'i386'
		assert f.arch == '*-i386'
		assert f.user_override == True
		assert str(f).startswith('<Feed from')

		try:
			f = model.Feed('http://feed', arch = 'i386', user_override = True)
			assert False
		except model.SafeException, ex:
			assert 'Malformed arch' in str(ex)
	
	def testCanonical(self):
		self.assertEquals('http://foo',
				model.canonical_iface_uri('http://foo'))
		try:
			model.canonical_iface_uri('bad-name')
			assert False
		except model.SafeException, ex:
			assert 'Bad interface name' in str(ex)
	
	def testVersions(self):
		pv = model.parse_version
		assert pv('1.0') > pv('0.9')
		assert pv('1.0') > pv('1')
		assert pv('1.0') == pv('1.0')
		assert pv('0.9.9') < pv('1.0')

		def invalid(v):
			try:
				pv(v)
				assert False
			except model.SafeException, ex:
				pass
		invalid('hello')
		invalid('2./1')
		invalid('.1')
		invalid('')

		# Check parsing
		assert pv('1') == [[1], 0]
		assert pv('1.0') == [[1,0], 0]
		assert pv('1.0-pre5') == [[1,0], -2, [5], 0]
		assert pv('1.0-rc5') == [[1,0], -1, [5], 0]
		assert pv('1.0-5') == [[1,0], 0, [5], 0]
		assert pv('1.0-post5') == [[1,0], 1, [5], 0]
		assert pv('1.0-post') == [[1,0], 1]
		assert pv('1-rc2.0-pre2-post') == [[1], -1, [2,0], -2, [2], 1]

		invalid('1-rc2.0-pre-post')

		assert pv('1.0-0') > pv('1.0')
		assert pv('1.0-1') > pv('1.0-0')
		assert pv('1.0-0') < pv('1.0-1')

		assert pv('1.0-pre99') > pv('1.0-pre1')
		assert pv('1.0-pre99') < pv('1.0-rc1')
		assert pv('1.0-rc1') < pv('1.0')
		assert pv('1.0') < pv('1.0-0')
		assert pv('1.0-0') < pv('1.0-post')

		assert pv('2-post999') < pv('3-pre1')

suite = unittest.makeSuite(TestModel)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
