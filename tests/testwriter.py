#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, StringIO
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import writer, model, reader, qdom

test_feed = qdom.parse(StringIO.StringIO("""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Test</name>
<summary>for testing</summary>
<implementation id='sha1=3ce644dc725f1d21cfcf02562c76f375944b266a' version='1'/>
</interface>
"""))

class TestWriter(BaseTest):
	def testFeeds(self):
		iface = model.Interface('http://test/test')
		iface._main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		iface.stability_policy = model.developer
		iface._main_feed.last_checked = 100
		iface.extra_feeds.append(model.Feed('http://sys-feed', None, False))
		iface.extra_feeds.append(model.Feed('http://user-feed', 'Linux-*', True))
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		iface._main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		reader.update_user_overrides(iface, iface._main_feed)
		self.assertEquals(model.developer, iface.stability_policy)
		self.assertEquals(100, iface.last_checked)
		self.assertEquals(None, iface.get_feed('http://sys-feed'))
		feed = iface.get_feed('http://user-feed')
		self.assertEquals('http://user-feed', feed.uri)
		self.assertEquals('Linux', feed.os)
		self.assertEquals(None, feed.machine)

	def testStoreNothing(self):
		iface = model.Interface('http://test/test')
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)
		self.assertEquals({}, iface.implementations)

	def testStoreStability(self):
		iface = model.Interface('http://example.com:8000/Hello.xml')
		iface._main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello.xml')
		impl = iface.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		impl.user_stability = model.developer
		writer.save_interface(iface)

		iface = model.Interface('http://example.com:8000/Hello.xml')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)

		# Ignored because not in main interface
		self.assertEquals(0, len(iface.implementations))

		# Now visible
		reader.update(iface, 'Hello.xml')
		reader.update_user_overrides(iface)
		self.assertEquals(1, len(iface.implementations))

		impl = iface.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		self.assertEquals(model.developer, impl.user_stability)

suite = unittest.makeSuite(TestWriter)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
