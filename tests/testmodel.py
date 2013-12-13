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

if __name__ == '__main__':
	unittest.main()
