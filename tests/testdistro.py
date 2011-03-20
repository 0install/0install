#!/usr/bin/env python
from basetest import BaseTest, empty_feed, DummyPackageKit
import sys, os, tempfile
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import distro, model, qdom, iface_cache, handler

def parse_impls(impls):
	xml = """<?xml version="1.0" ?>
		 <interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
		   <name>Foo</name>
		   <summary>Foo</summary>
		   <description>Foo</description>
		   %s
		</interface>""" % impls
	element = qdom.parse(StringIO(xml))
	return model.ZeroInstallFeed(element, "myfeed.xml")

class TestDistro(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')

	def tearDown(self):	
		BaseTest.tearDown(self)

	def testCache(self):
		src = tempfile.NamedTemporaryFile()
		try:
			cache = distro.Cache('test-cache', src.name, 1)
			self.assertEquals(None, cache.get("foo"))
			cache.put("foo", "1")
			self.assertEquals("1", cache.get("foo"))
			cache.put("foo", "2")
			self.assertEquals("2", cache.get("foo"))

			# new cache...
			cache = distro.Cache('test-cache', src.name, 1)
			self.assertEquals("2", cache.get("foo"))

			src.write("hi")
			src.flush()

			self.assertEquals(None, cache.get("foo"))
			cache.put("foo", "3")

			# new cache... (format change)
			cache = distro.Cache('test-cache', src.name, 2)
			self.assertEquals(None, cache.get("foo"))

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
		self.assertEquals(self.feed.implementations, {})

		# Special case: we can always find a version of Python
		master_feed = model.ZeroInstallFeed(None)
		master_feed.url = 'http://repo.roscidus.com/python/python'
		feed = host.get_feed(master_feed)
		self.assertEquals(1, len(feed.implementations))

	def testDebian(self):
		dpkgdir = os.path.join(os.path.dirname(__file__), 'dpkg')
		host = distro.DebianDistribution(
				os.path.join(dpkgdir, 'status'),
				os.path.join(dpkgdir, 'pkgcache.bin'))
		host._packagekit = DummyPackageKit()

		factory = self.make_factory(host)
		host.get_package_info('gimp', factory)
		self.assertEquals({}, self.feed.implementations)

		# Initially, we only get information about the installed version...
		host.get_package_info('python-bittorrent', factory)
		self.assertEquals(1, len(self.feed.implementations))

		# Tell distro to fetch information about candidates...
		master_feed = parse_impls("""<package-implementation package='python-bittorrent'/>""")
		h = handler.Handler()
		candidates = host.fetch_candidates(master_feed)
		if candidates:
			h.wait_for_blocker(candidates)
		# Now we see the uninstalled package
		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')
		host.get_package_info('python-bittorrent', factory)
		self.assertEquals(2, len(self.feed.implementations))

		self.assertEquals(2, len(self.feed.implementations))
		bittorrent_installed = self.feed.implementations['package:deb:python-bittorrent:3.4.2-10:*']
		bittorrent_uninstalled = self.feed.implementations['package:deb:python-bittorrent:3.4.2-11.1:*']
		self.assertEquals('3.4.2-10', bittorrent_installed.get_version())
		self.assertTrue(bittorrent_installed.installed)
		self.assertFalse(bittorrent_uninstalled.installed)
		self.assertEquals(None, bittorrent_installed.machine)

		self.feed = model.ZeroInstallFeed(empty_feed, local_path = '/empty.xml')
		host.get_package_info('libxcomposite-dev', factory)
		self.assertEquals(1, len(self.feed.implementations))
		libxcomposite = self.feed.implementations['package:deb:libxcomposite-dev:0.3.1-1:i386']
		self.assertEquals('0.3.1-1', libxcomposite.get_version())
		self.assertEquals('i386', libxcomposite.machine)
	
	def testRPM(self):
		rpmdir = os.path.join(os.path.dirname(__file__), 'rpm')
		os.environ['PATH'] = rpmdir + ':' + self.old_path
		rpm = distro.RPMDistribution(os.path.join(rpmdir, 'status'))

		self.assertEquals(2, len(rpm.versions))

		factory = self.make_factory(rpm)
		rpm.get_package_info('yast2-update', factory)
		self.assertEquals(1, len(self.feed.implementations))
		yast = self.feed.implementations['package:rpm:yast2-update:2.15.23-21:i586']
		self.assertEquals('2.15.23-21', yast.get_version())
		self.assertEquals('*-i586', yast.arch)

		icache = iface_cache.IfaceCache(distro = rpm)

		feed = parse_impls("""
				<package-implementation distributions="Debian" package="yast2-mail"/>
				<package-implementation distributions="RPM" package="yast2-update"/>
				""")
		icache._feeds[feed.url] = feed
		distro_feed_url = feed.get_distro_feed()
		impls = icache.get_feed(distro_feed_url).implementations
		self.assertEquals("distribution:myfeed.xml", distro_feed_url)
		assert len(impls) == 1, impls
		impl, = impls
		assert impl == 'package:rpm:yast2-update:2.15.23-21:i586'

		feed = parse_impls("""
				<package-implementation distributions="RPM" package="yast2-mail"/>
				<package-implementation distributions="RPM" package="yast2-update"/>
				""")
		icache._feeds[feed.url] = feed
		del icache._feeds['distribution:' + feed.url]
		impls = icache.get_feed(feed.get_distro_feed()).implementations
		assert len(impls) == 2, impls

		feed = parse_impls("""
				<package-implementation distributions="" package="yast2-mail"/>
				<package-implementation package="yast2-update"/>
				""")
		icache._feeds[feed.url] = feed
		del icache._feeds['distribution:' + feed.url]
		impls = icache.get_feed(feed.get_distro_feed()).implementations
		assert len(impls) == 2, impls

	def testSlack(self):
		slackdir = os.path.join(os.path.dirname(__file__), 'slack')
		slack = distro.SlackDistribution(os.path.join(slackdir, 'packages'))

		factory = self.make_factory(slack)
		slack.get_package_info('gimp', factory)
		self.assertEquals({}, self.feed.implementations)

		slack.get_package_info('infozip', factory)
		self.assertEquals(1, len(self.feed.implementations))
		zip = self.feed.implementations['package:slack:infozip:5.52-2:i486']
		self.assertEquals('5.52-2', zip.get_version())
		self.assertEquals('i486', zip.machine)

	def testGentoo(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'gentoo')
		ebuilds = distro.GentooDistribution(pkgdir)

		factory = self.make_factory(ebuilds)
		ebuilds.get_package_info('media-gfx/gimp', factory)
		self.assertEquals({}, self.feed.implementations)

		ebuilds.get_package_info('sys-apps/portage', factory)
		self.assertEquals(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-apps/portage:2.1.7.16:x86_64']
		self.assertEquals('2.1.7.16', impl.get_version())
		self.assertEquals('x86_64', impl.machine)

		ebuilds.get_package_info('sys-kernel/gentoo-sources', factory)
		self.assertEquals(3, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.30-4:i686']
		self.assertEquals('2.6.30-4', impl.get_version())
		self.assertEquals('i686', impl.machine)
		impl = self.feed.implementations['package:gentoo:sys-kernel/gentoo-sources:2.6.32:x86_64']
		self.assertEquals('2.6.32', impl.get_version())
		self.assertEquals('x86_64', impl.machine)

		ebuilds.get_package_info('app-emulation/emul-linux-x86-baselibs', factory)
		self.assertEquals(4, len(self.feed.implementations))
		impl = self.feed.implementations['package:gentoo:app-emulation/emul-linux-x86-baselibs:20100220:i386']
		self.assertEquals('20100220', impl.get_version())
		self.assertEquals('i386', impl.machine)

	def testPorts(self):
		pkgdir = os.path.join(os.path.dirname(__file__), 'ports')
		ports = distro.PortsDistribution(pkgdir)

		factory = self.make_factory(ports)
		ports.get_package_info('zeroinstall-injector', factory)
		self.assertEquals(1, len(self.feed.implementations))
		impl = self.feed.implementations['package:ports:zeroinstall-injector:0.41-2:' + distro.host_machine]
		self.assertEquals('0.41-2', impl.get_version())
		self.assertEquals(distro.host_machine, impl.machine)

	def testCleanVersion(self):
		self.assertEquals('0.3.1-1', distro.try_cleanup_distro_version('1:0.3.1-1'))
		self.assertEquals('0.3.1-1', distro.try_cleanup_distro_version('0.3.1-1ubuntu0'))
		self.assertEquals('0.3-post1-rc2', distro.try_cleanup_distro_version('0.3-post1-rc2'))
		self.assertEquals('0.3.1-2', distro.try_cleanup_distro_version('0.3.1-r2-r3'))

if __name__ == '__main__':
	unittest.main()
