#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import writer, model, basedir, reader

class TestTrust(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		reload(basedir)

		assert basedir.xdg_config_home == self.config_home
		os.mkdir(self.config_home, 0700)
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
	
	def testFeeds(self):
		iface = model.Interface('http://test/test')
		iface.stability_policy = model.developer
		iface.last_checked = 100
		iface.feeds.append(model.Feed('http://sys-feed', None, False))
		iface.feeds.append(model.Feed('http://user-feed', 'Linux-*', True))
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)
		self.assertEquals(model.developer, iface.stability_policy)
		self.assertEquals(100, iface.last_checked)
		self.assertEquals(None, iface.get_feed('http://sys-feed'))
		feed = iface.get_feed('http://user-feed')
		self.assertEquals('http://user-feed', feed.uri)
		self.assertEquals('Linux', feed.os)
		self.assertEquals(None, feed.machine)

	def testStoreNothing(self):
		iface = model.Interface('http://test/test')
		impl = iface.get_impl('/some/path')
		writer.save_interface(iface)

		iface = model.Interface('http://test/test')
		self.assertEquals(None, iface.stability_policy)
		reader.update_user_overrides(iface)
		self.assertEquals({}, iface.implementations)

	def testStoreStability(self):
		iface = model.Interface('http://localhost:8000/Hello')
		impl = iface.get_impl('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
		impl.user_stability = model.developer
		writer.save_interface(iface)

		iface = model.Interface('http://localhost:8000/Hello')
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

suite = unittest.makeSuite(TestTrust)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
