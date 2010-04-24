#!/usr/bin/env python
from basetest import BaseTest, empty_feed
import sys, os, tempfile
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import distro, model, qdom

def parse_impls(impls, test_distro):
	xml = """<?xml version="1.0" ?>
		 <interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
		   <name>Foo</name>
		   <summary>Foo</summary>
		   <description>Foo</description>
		   %s
		</interface>""" % impls
	element = qdom.parse(StringIO(xml))
	return model.ZeroInstallFeed(element, "myfeed.xml", test_distro)

class TestDistro(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')

	def tearDown(self):	
		BaseTest.tearDown(self)

	def testCache(self):
		src = tempfile.NamedTemporaryFile()
		try:
			cache = distro.Cache('test-cache', src.name)
			self.assertEquals(None, cache.get("foo"))
			cache.put("foo", "1")
			self.assertEquals("1", cache.get("foo"))
			cache.put("foo", "2")
			self.assertEquals("2", cache.get("foo"))

			# new cache...
			cache = distro.Cache('test-cache', src.name)
			self.assertEquals("2", cache.get("foo"))

			src.write("hi")
			src.flush()

			self.assertEquals("2", cache.get("foo"))

			# new cache...
			cache = distro.Cache('test-cache', src.name)
			self.assertEquals(None, cache.get("foo"))

		finally:
			src.close()

	def factory(self, id):
		impl = model.DistributionImplementation(self.feed, id)
		assert id not in self.feed.implementations
		self.feed.implementations[id] = impl
		return impl

	def testDefault(self):
		host = distro.Distribution()

		host.get_package_info('gimp', self.factory)
		self.assertEquals(self.feed.implementations, {})

	def testDebian(self):
		dpkgdir = os.path.join(os.path.dirname(__file__), 'dpkg')
		host = distro.DebianDistribution(
				os.path.join(dpkgdir, 'status'),
				os.path.join(dpkgdir, 'pkgcache.bin'))

		self.assertEquals(2, len(host.versions))

		host.get_package_info('gimp', self.factory)
		self.assertEquals({}, self.feed.implementations)

		host.get_package_info('python-bittorrent', self.factory)
		self.assertEquals(2, len(self.feed.implementations))
		bittorrent_installed = self.feed.implementations['package:deb:python-bittorrent:3.4.2-10']
		bittorrent_uninstalled = self.feed.implementations['package:deb:python-bittorrent:3.4.2-11.1']
		self.assertEquals('3.4.2-10', bittorrent_installed.get_version())
		self.assertTrue(bittorrent_installed.installed)
		self.assertFalse(bittorrent_uninstalled.installed)
		self.assertEquals(None, bittorrent_installed.machine)

		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')
		host.get_package_info('libxcomposite-dev', self.factory)
		self.assertEquals(1, len(self.feed.implementations))
		libxcomposite = self.feed.implementations['package:deb:libxcomposite-dev:0.3.1-1']
		self.assertEquals('0.3.1-1', libxcomposite.get_version())
		self.assertEquals('i386', libxcomposite.machine)
	
	def testRPM(self):
		rpmdir = os.path.join(os.path.dirname(__file__), 'rpm')
		os.environ['PATH'] = rpmdir + ':' + self.old_path
		rpm = distro.RPMDistribution(os.path.join(rpmdir, 'status'))

		self.assertEquals(2, len(rpm.versions))

		rpm.get_package_info('yast2-update', self.factory)
		self.assertEquals(1, len(self.feed.implementations))
		yast = self.feed.implementations['package:rpm:yast2-update:2.15.23-21:i586']
		self.assertEquals('2.15.23-21', yast.get_version())
		self.assertEquals('*-i586', yast.arch)

		impls = parse_impls("""
				<package-implementation distributions="Debian" package="yast2-mail"/>
				<package-implementation distributions="RPM" package="yast2-update"/>
				""", rpm).implementations
		assert len(impls) == 1, impls
		impl, = impls
		assert impl == 'package:rpm:yast2-update:2.15.23-21:i586'

		impls = parse_impls("""
				<package-implementation distributions="RPM" package="yast2-mail"/>
				<package-implementation distributions="RPM" package="yast2-update"/>
				""", rpm).implementations
		assert len(impls) == 2, impls

		impls = parse_impls("""
				<package-implementation distributions="" package="yast2-mail"/>
				<package-implementation package="yast2-update"/>
				""", rpm).implementations
		assert len(impls) == 2, impls

	def testGentoo(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'gentoo')
		ebuilds = distro.GentooDistribution(pkgdir)

		ebuilds.get_package_info('media-gfx/gimp', self.factory)
		self.assertEquals({}, self.feed.implementations)

		ebuilds.get_package_info('sys-apps/portage', self.factory)
		self.assertEquals(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-apps/portage:2.1.7.16:x86_64']
		self.assertEquals('2.1.7.16', impl.get_version())
		self.assertEquals('x86_64', impl.machine)

		ebuilds.get_package_info('sys-kernel/gentoo-sources', self.factory)
		self.assertEquals(3, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.30-4:i686']
		self.assertEquals('2.6.30-4', impl.get_version())
		self.assertEquals('i686', impl.machine)
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.32:x86_64']
		self.assertEquals('2.6.32', impl.get_version())
		self.assertEquals('x86_64', impl.machine)

		ebuilds.get_package_info('app-emulation/emul-linux-x86-baselibs', self.factory)
		self.assertEquals(4, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:app-emulation/emul-linux-x86-baselibs:20100220:i386']
		self.assertEquals('20100220', impl.get_version())
		self.assertEquals('i386', impl.machine)

	def testPorts(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'ports')
		ports = distro.PortsDistribution(pkgdir)

		ports.get_package_info('zeroinstall-injector', self.factory)
		self.assertEquals(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:ports:zeroinstall-injector:0.41:x86_64']
		self.assertEquals('0.41', impl.get_version())
		self.assertEquals('x86_64', impl.machine)

	def testCleanVersion(self):
		self.assertEquals('1', distro.try_cleanup_distro_version('1:0.3.1-1'))
		self.assertEquals('0.3.1-1', distro.try_cleanup_distro_version('0.3.1-1ubuntu0'))
		self.assertEquals('0.3-post1-rc2', distro.try_cleanup_distro_version('0.3-post1-rc2'))
		self.assertEquals('0.3.1-2', distro.try_cleanup_distro_version('0.3.1-r2-r3'))

if __name__ == '__main__':
	unittest.main()
