#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals
import basetest
from basetest import BaseTest, empty_feed
import sys, os
from xml.dom import minidom
import unittest
from io import BytesIO

sys.path.insert(0, '..')
from zeroinstall.injector import model, qdom, namespaces

mydir = os.path.dirname(os.path.abspath(__file__))

class TestModel(BaseTest):
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
	
	def testBadInterface(self):
		try:
			model.Interface('foo')
			assert 0
		except model.SafeException:
			pass
	
	def testInterface(self):
		i = model.Interface('http://foo')
		self.assertEqual('(foo)', i.get_name())
		feed = model.ZeroInstallFeed(empty_feed, local_path = '/foo')
		self.assertEqual('Empty', feed.get_name())
		repr(i)

	def testMetadata(self):
		main_feed = model.ZeroInstallFeed(empty_feed, local_path = '/foo')
		assert main_feed.local_path == "/foo"
		e = qdom.parse(BytesIO(b'<ns:b xmlns:ns="a" foo="bar"/>'))
		main_feed.metadata = [e]
		assert main_feed.get_metadata('a', 'b') == [e]
		assert main_feed.get_metadata('b', 'b') == []
		assert main_feed.get_metadata('a', 'a') == []
		assert e.getAttribute('foo') == 'bar'
		self.assertEqual(None, main_feed.get_replaced_by())

	def testLocale(self):
		local_path = os.path.join(mydir, 'Local.xml')
		with open(local_path, 'rb') as stream:
			dom = qdom.parse(stream)
		feed = model.ZeroInstallFeed(dom, local_path = local_path)
		# (defaults to en-US if no language is set in the locale)
		self.assertEqual("Local feed (English)", feed.summary)
		self.assertEqual("English", feed.description)

		self.assertEqual(4, len(feed.summaries))
		self.assertEqual(2, len(feed.descriptions))

		try:
			basetest.test_locale = ('es_ES', 'UTF8')

			self.assertEqual("Fuente local", feed.summary)
			self.assertEqual("Español", feed.description)

			basetest.test_locale = ('en_GB', 'UTF8')

			self.assertEqual("Local feed (English GB)", feed.summary)

			basetest.test_locale = ('fr_FR', 'UTF8')

			self.assertEqual("Local feed (English)", feed.summary)
			self.assertEqual("English", feed.description)
		finally:
			basetest.test_locale = (None, None)

	def testCommand(self):
		local_path = os.path.join(mydir, 'Command.xml')
		with open(local_path, 'rb') as stream:
			dom = qdom.parse(stream)
		feed = model.ZeroInstallFeed(dom, local_path = local_path)

		assert feed.implementations['a'].main == 'foo'
		assert feed.implementations['a'].commands['run'].path == 'foo'
		assert feed.implementations['a'].commands['test'].path == 'test-foo'

		assert feed.implementations['b'].main == 'bar'
		assert feed.implementations['b'].commands['run'].path == 'bar'
		assert feed.implementations['b'].commands['test'].path == 'test-foo'

		assert feed.implementations['c'].main == 'test-gui'
		assert feed.implementations['c'].commands['run'].path == 'test-gui'
		assert feed.implementations['c'].commands['test'].path == 'test-baz'

	def testStabPolicy(self):
		i = model.Interface('http://foo')
		self.assertEqual(None, i.stability_policy)
		i.set_stability_policy(model.buggy)
		self.assertEqual(model.buggy, i.stability_policy)

	def testImpl(self):
		f = model.ZeroInstallFeed(None)
		f.url = 'http://foo'
		a = model.ZeroInstallImplementation(f, 'foo', None)
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
		self.assertEqual('1.2.3', a.get_version())
		a.version = model.parse_version('1.2.3-rc2-post')
		self.assertEqual('1.2.3-rc2-post', a.get_version())
		assert str(a) == 'foo'

		b = model.ZeroInstallImplementation(f, 'foo', None)
		b.version = model.parse_version("1.2.1")
		assert b > a
	
	def testDownloadSource(self):
		f = model.ZeroInstallFeed(empty_feed, local_path = '/foo')
		a = model.ZeroInstallImplementation(f, 'foo', None)
		a.add_download_source('ftp://foo', 1024, None)
		a.add_download_source('ftp://foo.tgz', 1025, 'foo')
		assert a.download_sources[0].url == 'ftp://foo'
		assert a.download_sources[0].size == 1024
		assert a.download_sources[0].extract == None
		assert a.feed is f
	
	def testEnvBind(self):
		a = model.EnvironmentBinding('PYTHONPATH', 'path')
		assert a.name == 'PYTHONPATH'
		assert a.insert == 'path'
		str(a)
	
	def testEnvModes(self):
		prepend = model.EnvironmentBinding('PYTHONPATH', 'lib', None, model.EnvironmentBinding.PREPEND)
		assert prepend.name == 'PYTHONPATH'
		assert prepend.insert == 'lib'
		assert prepend.mode is model.EnvironmentBinding.PREPEND

		self.assertEqual('/impl/lib:/usr/lib', prepend.get_value('/impl', '/usr/lib'))
		self.assertEqual('/impl/lib', prepend.get_value('/impl', None))

		append = model.EnvironmentBinding('PYTHONPATH', 'lib', '/opt/lib', model.EnvironmentBinding.APPEND)
		assert append.name == 'PYTHONPATH'
		assert append.insert == 'lib'
		assert append.mode is model.EnvironmentBinding.APPEND

		self.assertEqual('/usr/lib:/impl/lib', append.get_value('/impl', '/usr/lib'))
		self.assertEqual('/opt/lib:/impl/lib', append.get_value('/impl', None))
		
		append = model.EnvironmentBinding('PYTHONPATH', 'lib', None, model.EnvironmentBinding.REPLACE)
		assert append.name == 'PYTHONPATH'
		assert append.insert == 'lib'
		assert append.mode is model.EnvironmentBinding.REPLACE

		self.assertEqual('/impl/lib', append.get_value('/impl', '/usr/lib'))
		self.assertEqual('/impl/lib', append.get_value('/impl', None))

		assert model.EnvironmentBinding('PYTHONPATH', 'lib').mode == model.EnvironmentBinding.PREPEND

	def testOverlay(self):
		for xml, expected in [(b'<overlay/>', '<overlay . on />'),
				      (b'<overlay src="usr"/>', '<overlay usr on />'),
				      (b'<overlay src="package" mount-point="/usr/games"/>', '<overlay package on /usr/games>')]:
			e = qdom.parse(BytesIO(xml))
			ol = model.process_binding(e)
			self.assertEqual(expected, str(ol))

			doc = minidom.parseString('<doc/>')
			new_xml = ol._toxml(doc, None).toxml(encoding = 'utf-8')
			new_e = qdom.parse(BytesIO(new_xml))
			new_ol = model.process_binding(new_e)
			self.assertEqual(expected, str(new_ol))

	def testReplaced(self):
		local_path = os.path.join(mydir, 'Replaced.xml')
		with open(local_path, 'rb') as stream:
			dom = qdom.parse(stream)
		feed = model.ZeroInstallFeed(dom, local_path = local_path)
		self.assertEqual("http://localhost:8000/Hello", feed.get_replaced_by())

	def testDep(self):
		b = model.InterfaceDependency('http://foo', element = qdom.Element(namespaces.XMLNS_IFACE, 'requires', {}))
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
		except model.SafeException as ex:
			assert 'Malformed arch' in str(ex)
	
	def testCanonical(self):
		# HTTP
		try:
			model.canonical_iface_uri('http://foo')
			assert False
		except model.SafeException as ex:
			assert 'Missing /' in str(ex)

		self.assertEqual('http://foo/',
				model.canonical_iface_uri('http://foo/'))
		try:
			model.canonical_iface_uri('bad-name')
			assert False
		except model.SafeException as ex:
			assert 'Bad interface name' in str(ex)

		# Bare relative path
		model.canonical_iface_uri('Command.xml')
		try:
			model.canonical_iface_uri('CommandMissing.xml')
			assert False
		except model.SafeException as ex:
			assert "Bad interface name 'CommandMissing.xml'" in str(ex), ex

		# file:absolute
		model.canonical_iface_uri('file://{path}/Command.xml'.format(path = mydir))
		try:
			model.canonical_iface_uri('file://{path}/CommandMissing.xml'.format(path = mydir))
			assert False
		except model.SafeException as ex:
			assert "Bad interface name 'file://" in str(ex), ex

		# file:relative
		model.canonical_iface_uri('file:Command.xml')
		try:
			model.canonical_iface_uri('file:CommandMissing.xml')
			assert False
		except model.SafeException as ex:
			assert "Bad interface name 'file:CommandMissing.xml'" in str(ex), ex

	
	def testVersions(self):
		def pv(v):
			parsed = model.parse_version(v)
			assert model.format_version(parsed) == v
			return parsed

		assert pv('1.0') > pv('0.9')
		assert pv('1.0') > pv('1')
		assert pv('1.0') == pv('1.0')
		assert pv('0.9.9') < pv('1.0')
		assert pv('10') > pv('2')

		def invalid(v):
			try:
				pv(v)
				assert False
			except model.SafeException:
				pass
		invalid('.')
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
		assert pv('1-rc2.0-pre-post') == [[1], -1, [2,0], -2, [], 1]

		assert pv('1.0-0') > pv('1.0')
		assert pv('1.0-1') > pv('1.0-0')
		assert pv('1.0-0') < pv('1.0-1')

		assert pv('1.0-pre99') > pv('1.0-pre1')
		assert pv('1.0-pre99') < pv('1.0-rc1')
		assert pv('1.0-rc1') < pv('1.0')
		assert pv('1.0') < pv('1.0-0')
		assert pv('1.0-0') < pv('1.0-post')
		assert pv('2.1.9-pre-1') > pv('2.1.9-pre')

		assert pv('2-post999') < pv('3-pre1')

	def testRanges(self):
		r = model.VersionExpressionRestriction('2.6..!3 | 3.2.2.. | 1 | ..!0.2')

		def test(v, result):
			class DummyImpl:
				version = model.parse_version(v)
			self.assertEqual(result, r.meets_restriction(DummyImpl()))

		test('0.1', True)
		test('0.2', False)
		test('0.3', False)
		test('1', True)
		test('2.5', False)
		test('2.6', True)
		test('2.7', True)
		test('3-pre', True)
		test('3', False)
		test('3.1', False)
		test('3.2.1', False)
		test('3.2.2', True)
		test('3.3', True)

		r = model.VersionExpressionRestriction('!7')
		test('1', True)
		test('7', False)
		test('8', True)

		def fail(expr, msg):
			try:
				model.VersionExpressionRestriction(expr)
				assert 0
			except model.SafeException as ex:
				self.assertEqual(msg, str(ex))

		fail('1..2', "End of range must be exclusive (use '..!2', not '..2')")
		fail('.2', "Invalid version format in '.2': invalid literal for int() with base 10: ''")
		fail('0.2-hi', "Invalid version modifier in '0.2-hi': 'hi'")

if __name__ == '__main__':
	unittest.main()
