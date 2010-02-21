#!/usr/bin/env python2.5
from basetest import BaseTest, empty_feed
import sys, os
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
		host = distro.DebianDistribution(os.path.join(dpkgdir, 'status'))

		self.assertEquals(2, len(host.versions))

		host.get_package_info('gimp', self.factory)
		self.assertEquals({}, self.feed.implementations)

		host.get_package_info('python-bittorrent', self.factory)
		self.assertEquals(1, len(self.feed.implementations))
		bittorrent = self.feed.implementations['package:deb:python-bittorrent:3.4.2-10']
		self.assertEquals('3.4.2-10', bittorrent.get_version())

		host.get_package_info('libxcomposite-dev', self.factory)
		self.assertEquals(2, len(self.feed.implementations))
		libxcomposite = self.feed.implementations['package:deb:libxcomposite-dev:0.3.1-1']
		self.assertEquals('0.3.1-1', libxcomposite.get_version())
	
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

		ebuilds.get_package_info('sys-kernel/gentoo-sources', self.factory)
		self.assertEquals(3, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.30-4:i686']
		self.assertEquals('2.6.30-4', impl.get_version())
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.32:x86_64']
		self.assertEquals('2.6.32', impl.get_version())

	def testCleanVersion(self):
		self.assertEquals('1', distro.try_cleanup_distro_version('1:0.3.1-1'))
		self.assertEquals('0.3.1-1', distro.try_cleanup_distro_version('0.3.1-1ubuntu0'))
		self.assertEquals('0.3-post1-rc2', distro.try_cleanup_distro_version('0.3-post1-rc2'))
		self.assertEquals('0.3.1-2', distro.try_cleanup_distro_version('0.3.1-r2-r3'))

suite = unittest.makeSuite(TestDistro)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
