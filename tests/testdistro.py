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

	def testCache(self):
		src = tempfile.NamedTemporaryFile(mode = 'wt')
		try:
			cache = distro.Cache('test-cache', src.name, 1)
			self.assertEqual(None, cache.get("foo"))
			cache.put("foo", "1")
			self.assertEqual("1", cache.get("foo"))
			cache.put("foo", "2")
			self.assertEqual("2", cache.get("foo"))

			# new cache...
			cache = distro.Cache('test-cache', src.name, 1)
			self.assertEqual("2", cache.get("foo"))

			src.write("hi")
			src.flush()

			self.assertEqual(None, cache.get("foo"))
			cache.put("foo", "3")

			# new cache... (format change)
			cache = distro.Cache('test-cache', src.name, 2)
			self.assertEqual(None, cache.get("foo"))

		finally:
			src.close()

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
	
	def testSlack(self):
		slackdir = os.path.join(os.path.dirname(__file__), 'slack')
		slack = distro.SlackDistribution(os.path.join(slackdir, 'packages'))

		factory = self.make_factory(slack)
		slack.get_package_info('gimp', factory)
		self.assertEqual({}, self.feed.implementations)

		slack.get_package_info('infozip', factory)
		self.assertEqual(1, len(self.feed.implementations))
		zip = self.feed.implementations['package:slack:infozip:5.52-2:i486']
		self.assertEqual('5.52-2', zip.get_version())
		self.assertEqual('i486', zip.machine)

	def testArch(self):
		archdir = os.path.join(os.path.dirname(__file__), 'arch')
		arch = distro.ArchDistribution(archdir)

		factory = self.make_factory(arch)
		arch.get_package_info('gimp', factory)
		self.assertEqual({}, self.feed.implementations)

		arch.get_package_info('zeroinstall-injector', factory)
		self.assertEqual(1, len(self.feed.implementations))
		zip = self.feed.implementations['package:arch:zeroinstall-injector:1.5-1:*']
		self.assertEqual('1.5-1', zip.get_version())

		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')
		arch.get_package_info('python2', factory)
		impl, = self.feed.implementations.values()
		self.assertEqual('2.7.2-4', impl.get_version())

	def testGentoo(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'gentoo')
		ebuilds = distro.GentooDistribution(pkgdir)

		factory = self.make_factory(ebuilds)
		ebuilds.get_package_info('media-gfx/gimp', factory)
		self.assertEqual({}, self.feed.implementations)

		ebuilds.get_package_info('sys-apps/portage', factory)
		self.assertEqual(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-apps/portage:2.1.7.16:x86_64']
		self.assertEqual('2.1.7.16', impl.get_version())
		self.assertEqual('x86_64', impl.machine)

		ebuilds.get_package_info('sys-kernel/gentoo-sources', factory)
		self.assertEqual(3, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.30-4:i686']
		self.assertEqual('2.6.30-4', impl.get_version())
		self.assertEqual('i686', impl.machine)
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.32:x86_64']
		self.assertEqual('2.6.32', impl.get_version())
		self.assertEqual('x86_64', impl.machine)

		ebuilds.get_package_info('app-emulation/emul-linux-x86-baselibs', factory)
		self.assertEqual(4, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:app-emulation/emul-linux-x86-baselibs:20100220:i386']
		self.assertEqual('20100220', impl.get_version())
		self.assertEqual('i386', impl.machine)

	def testPorts(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'ports')
		ports = distro.PortsDistribution(pkgdir)

		factory = self.make_factory(ports)
		ports.get_package_info('zeroinstall-injector', factory)
		self.assertEqual(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:ports:zeroinstall-injector:0.41-2:' + distro.host_machine]
		self.assertEqual('0.41-2', impl.get_version())
		self.assertEqual(distro.host_machine, impl.machine)

	def testMacPorts(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'macports')
		os.environ['PATH'] = pkgdir + ':' + self.old_path
		ports = distro.MacPortsDistribution(os.path.join(pkgdir, 'registry.db'))

		factory = self.make_factory(ports)
		ports.get_package_info('zeroinstall-injector', factory)
		self.assertEqual(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:macports:zeroinstall-injector:1.0-0:*']
		self.assertEqual('1.0-0', impl.get_version())
		self.assertEqual(None, impl.machine)

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
