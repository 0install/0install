#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals
import basetest
from basetest import BaseTest, empty_feed
import sys, os
import unittest
from io import BytesIO

sys.path.insert(0, '..')
from zeroinstall.injector import model, qdom

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

	def testReplaced(self):
		local_path = os.path.join(mydir, 'Replaced.xml')
		with open(local_path, 'rb') as stream:
			dom = qdom.parse(stream)
		feed = model.ZeroInstallFeed(dom, local_path = local_path)
		self.assertEqual("http://localhost:8000/Hello", feed.get_replaced_by())

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
			assert "/tests/CommandMissing.xml' either" in str(ex), ex

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

if __name__ == '__main__':
	unittest.main()
