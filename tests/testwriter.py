#!/usr/bin/env python
from basetest import BaseTest
import sys, StringIO, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import writer, model, reader, qdom
from zeroinstall.support import basedir

test_feed = qdom.parse(StringIO.StringIO("""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Test</name>
<summary>for testing</summary>
<implementation id='sha1=3ce644dc725f1d21cfcf02562c76f375944b266a' version='1'/>
</interface>
"""))

mydir = os.path.dirname(__file__)

class TestWriter(BaseTest):
	def testFeeds(self):
		iface = model.Interface('http://test/test')
		main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		self.config.iface_cache._feeds[iface.uri] = main_feed
		iface.stability_policy = model.developer
		main_feed.last_checked = 100
		iface.extra_feeds.append(model.Feed('http://sys-feed', None, False))
		iface.extra_feeds.append(model.Feed('http://user-feed', 'Linux-*', True))
		writer.save_interface(iface)
		writer.save_feed(main_feed)

		iface = model.Interface('http://test/test')
		self.assertEqual(None, iface.stability_policy)
		main_feed = model.ZeroInstallFeed(test_feed, local_path = '/Hello')
		self.config.iface_cache._feeds[iface.uri] = main_feed
		reader.update_user_overrides(iface)
		reader.update_user_feed_overrides(main_feed)
		self.assertEqual(model.developer, iface.stability_policy)
		self.assertEqual(100, main_feed.last_checked)
		self.assertEqual("[<Feed from http://user-feed>]", str(iface.extra_feeds))

		feed = iface.extra_feeds[0]
		self.assertEqual('http://user-feed', feed.uri)
		self.assertEqual('Linux', feed.os)
		self.assertEqual(None, feed.machine)

	def testStoreNothing(self):
		iface = model.Interface('http://test/test')
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEqual(None, iface.stability_policy)
		reader.update_user_overrides(iface)

		feed = self.config.iface_cache.get_feed(iface.uri)
		self.assertEqual(None, feed)

	def testStoreStability(self):
		main_feed = reader.load_feed('Hello.xml', local = True)
		impl = main_feed.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		impl.user_stability = model.developer
		writer.save_feed(main_feed)

		# Rating now visible
		main_feed = reader.load_feed('Hello.xml', local = True)
		reader.update_user_feed_overrides(main_feed)
		self.assertEqual(1, len(main_feed.implementations))

		impl = main_feed.implementations['sha1=3ce644dc725f1d21cfcf02562c76f375944b266a']
		self.assertEqual(model.developer, impl.user_stability)
	
	def testSitePackages(self):
		# The old system (0install < 1.9):
		# - 0compile stores implementations to ~/.cache, and 
		# - adds to extra_feeds
		# The new system (0install >= 1.9):
		# - 0compile stores implementations to ~/.local/0install.net/site-packages, and
		# - 0install finds them automatically

		# For backwards compatibility, 0install >= 1.9:
		# - writes discovered feeds to extra_feeds
		# - skips such entries in extra_feeds when loading

		meta_dir = basedir.save_data_path('0install.net', 'site-packages',
						   'http:##example.com#prog.xml', '1.0', '0install')
		feed = os.path.join(meta_dir, 'feed.xml')
		shutil.copyfile(os.path.join(mydir, 'Local.xml'), feed)

		# Check that we find the feed without us having to register it
		iface = self.config.iface_cache.get_interface('http://example.com/prog.xml')
		self.assertEqual(1, len(iface.extra_feeds))
		site_feed, = iface.extra_feeds
		self.assertEqual(True, site_feed.site_package)

		# Check that we write it out, so that older 0installs can find it
		writer.save_interface(iface)

		config_file = basedir.load_first_config('0install.net', 'injector',
							'interfaces', 'http:##example.com#prog.xml')
		with open(config_file) as s:
			doc = qdom.parse(s)

		feed_node = None
		for item in doc.childNodes:
			if item.name == 'feed':
				feed_node = item
		self.assertEqual('True', feed_node.getAttribute('site-package'))

		# Check we ignore this element
		iface.reset()
		self.assertEqual([], iface.extra_feeds)
		reader.update_user_overrides(iface)
		self.assertEqual([], iface.extra_feeds)

		# Check feeds are automatically removed again
		reader.update_from_cache(iface)
		self.assertEqual(1, len(iface.extra_feeds))
		shutil.rmtree(basedir.load_first_data('0install.net', 'site-packages',
							'http:##example.com#prog.xml'))

		reader.update_from_cache(iface)
		self.assertEqual(0, len(iface.extra_feeds))

if __name__ == '__main__':
	unittest.main()
