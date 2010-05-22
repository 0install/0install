#!/usr/bin/env python
from basetest import BaseTest
import sys, StringIO
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import writer, model, reader, qdom, iface_cache

test_feed = qdom.parse(StringIO.StringIO("""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Test</name>
<summary>for testing</summary>
<implementation id='sha1=3ce644dc725f1d21cfcf02562c76f375944b266a' version='1'/>
</interface>
"""))

class TestWriter(BaseTest):
	def testFeeds(self):
		iface = model.Interface('http://test/test')
		main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		iface_cache.iface_cache._feeds[iface.uri] = main_feed
		iface.stability_policy = model.developer
		main_feed.last_checked = 100
		iface.extra_feeds.append(model.Feed('http://sys-feed', None, False))
		iface.extra_feeds.append(model.Feed('http://user-feed', 'Linux-*', True))
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		iface_cache.iface_cache._feeds[iface.uri] = main_feed
		reader.update_user_overrides(iface, main_feed)
		self.assertEquals(model.developer, iface.stability_policy)
		self.assertEquals(100, main_feed.last_checked)
		self.assertEquals("[<Feed from http://user-feed>]", str(iface.extra_feeds))

		feed = iface.extra_feeds[0]
		self.assertEquals('http://user-feed', feed.uri)
		self.assertEquals('Linux', feed.os)
		self.assertEquals(None, feed.machine)

	def testStoreNothing(self):
		iface = model.Interface('http://test/test')
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)

		feed = iface_cache.iface_cache.get_feed(iface.uri)
		self.assertEquals(None, feed)

	def testStoreStability(self):
		iface = model.Interface('http://example.com:8000/Hello.xml')
		main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello.xml')
		iface_cache.iface_cache._feeds[iface.uri] = main_feed
		impl = main_feed.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		impl.user_stability = model.developer
		writer.save_interface(iface)

		iface = model.Interface('http://example.com:8000/Hello.xml')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)

		del iface_cache.iface_cache._feeds[iface.uri]

		# Now visible
		reader.update(iface, 'Hello.xml')
		main_feed = iface_cache.iface_cache.get_feed(iface.uri)
		reader.update_user_overrides(iface, main_feed)
		self.assertEquals(1, len(main_feed.implementations))

		impl = main_feed.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		self.assertEquals(model.developer, impl.user_stability)

if __name__ == '__main__':
	unittest.main()
