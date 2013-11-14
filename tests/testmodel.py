#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals
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
