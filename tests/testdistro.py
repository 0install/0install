#!/usr/bin/env python
from basetest import BaseTest, empty_feed
import sys, os, tempfile, imp
from io import BytesIO
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import distro, model, qdom
from zeroinstall.support import basedir

def parse_impls(impls):
	xml = """<?xml version="1.0" ?>
		 <interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
		   <name>Foo</name>
		   <summary>Foo</summary>
		   <description>Foo</description>
		   {impls}
		</interface>""".format(impls = impls)
	element = qdom.parse(BytesIO(xml.encode('utf-8')))
	return model.ZeroInstallFeed(element, "myfeed.xml")

class TestDistro(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')

	def tearDown(self):	
		BaseTest.tearDown(self)

	def make_factory(self, distro):
		def factory(id, only_if_missing = False, installed = True):
			assert not only_if_missing
			impl = model.DistributionImplementation(self.feed, id, distro)
			assert id not in self.feed.implementations
			self.feed.implementations[id] = impl
			impl.installed = installed
			return impl
		return factory

	def testDefault(self):
		host = distro.Distribution()

		factory = self.make_factory(host)
		host.get_package_info('gimp', factory)
		self.assertEqual(self.feed.implementations, {})

	def testCleanVersion(self):
		self.assertEqual('0.3.1-1', distro.try_cleanup_distro_version('1:0.3.1-1'))
		self.assertEqual('0.3.1-1', distro.try_cleanup_distro_version('0.3.1-1ubuntu0'))
		self.assertEqual('0.3-post1-rc2', distro.try_cleanup_distro_version('0.3-post1-rc2'))
		self.assertEqual('0.3.1-2', distro.try_cleanup_distro_version('0.3.1-r2-r3'))
		self.assertEqual('6.17', distro.try_cleanup_distro_version('6b17'))
		self.assertEqual('20-1', distro.try_cleanup_distro_version('b20_1'))
		self.assertEqual('17', distro.try_cleanup_distro_version('p17'))
		self.assertEqual('7-pre3-2.1.1-3', distro.try_cleanup_distro_version('7~u3-2.1.1-3'))	# Debian snapshot
		self.assertEqual('7-pre3-2.1.1-pre1-1', distro.try_cleanup_distro_version('7~u3-2.1.1~pre1-1ubuntu2'))
		self.assertEqual(None, distro.try_cleanup_distro_version('cvs'))

	def testPortable(self):
		# Overrides all XDG_* variables
		os.environ['ZEROINSTALL_PORTABLE_BASE'] = '/portable'
		imp.reload(basedir)
		self.assertEqual('/portable/config', basedir.xdg_config_home)
		self.assertEqual('/portable/cache', basedir.xdg_cache_home)
		self.assertEqual('/portable/data', basedir.xdg_data_home)

		self.assertEqual(['/portable/config'], basedir.xdg_config_dirs)
		self.assertEqual(['/portable/cache'], basedir.xdg_cache_dirs)
		self.assertEqual(['/portable/data'], basedir.xdg_data_dirs)

		del os.environ['ZEROINSTALL_PORTABLE_BASE']
		os.environ['XDG_CONFIG_HOME'] = '/home/me/config'
		os.environ['XDG_CONFIG_DIRS'] = '/system/config'

		os.environ['XDG_DATA_HOME'] = '/home/me/data'
		os.environ['XDG_DATA_DIRS'] = '/system/data' + os.pathsep + '/disto/data'

		os.environ['XDG_CACHE_HOME'] = '/home/me/cache'
		os.environ['XDG_CACHE_DIRS'] = '/system/cache'
		imp.reload(basedir)

		self.assertEqual('/home/me/config', basedir.xdg_config_home)
		self.assertEqual('/home/me/cache', basedir.xdg_cache_home)
		self.assertEqual('/home/me/data', basedir.xdg_data_home)

		self.assertEqual(['/home/me/config', '/system/config'], basedir.xdg_config_dirs)
		self.assertEqual(['/home/me/cache', '/system/cache'], basedir.xdg_cache_dirs)
		self.assertEqual(['/home/me/data', '/system/data', '/disto/data'], basedir.xdg_data_dirs)

if __name__ == '__main__':
	unittest.main()
