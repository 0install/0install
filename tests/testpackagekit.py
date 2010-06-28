#!/usr/bin/env python
from basetest import BaseTest
import sys
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import packagekit, handler, model
from zeroinstall.support import tasks

h = handler.Handler()

import dbus

class PackageKit05:
	x = 0

	def GetTid(self):
		self.x += 1
		return "/tid/%d" % self.x

	class Tid:
		def __init__(self):
			self.signals = {}

		def connect_to_signal(self, signal, cb):
			self.signals[signal] = cb

		def get_dbus_method(self, method):
			if hasattr(self, method):
				return getattr(self, method)
			raise dbus.exceptions.DBusException('org.freedesktop.DBus.Error.UnknownMethod')

		def SetLocale(self, locale):
			pass

	class Tid1(Tid):
		def Resolve(self, query, package_names):
			@tasks.async
			def later():
				yield
				result = "success"
				for package_name in package_names:
					if package_name == 'gimp':
						info = {}
						self.signals['Package'](info, "gimp;2.6.8-2ubuntu1.1;amd64;Ubuntu", "summary")
					else:
						self.signals['Error']("package-not-found", "Package name %s could not be resolved" % package_name)
						result = "failed"
				yield
				self.signals['Finished'](result, 100)
			later()

	class Tid2(Tid):
		def GetDetails(self, package_ids):
			@tasks.async
			def later():
				yield
				for package_id in package_ids:
					assert package_id == "gimp;2.6.8-2ubuntu1.1;amd64;Ubuntu"
					self.signals['Details'](package_id, "GPL", "Graphics", "detail", "http://foo", 100)

				yield
				self.signals['Finished']("success", 100)
			later()

class TestPackageKit(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

	def tearDown(self):
		sys.meta_path = []
		BaseTest.tearDown(self)

	def find_module(self, fullname, path=None):
		if fullname.startswith('dbus'):
			raise ImportError("No (dummy) D-BUS")
		else:
			return None

	def testNoDBUS(self):
		import dbus
		old_dbus = dbus
		try:
			sys.meta_path = [self]
			del sys.modules['dbus']

			reload(packagekit)

			pk = packagekit.PackageKit()
			assert pk.available == False

			factory = Exception("not called")
			pk.get_candidates('gimp', factory, 'package:null')
		finally:
			self.meta_path = []
			sys.modules['dbus'] = old_dbus

	def testNoPackageKit(self):
		reload(packagekit)
		pk = packagekit.PackageKit()
		assert not pk.available

		factory = Exception("not called")
		pk.get_candidates('gimp', factory, 'package:null')

	def testPackageKit05(self):
		#import logging; logging.getLogger().setLevel(logging.DEBUG)

		dbus.system_services['org.freedesktop.PackageKit'] = {
			'/org/freedesktop/PackageKit': PackageKit05(),
			'/tid/1': PackageKit05.Tid1(),
			'/tid/2': PackageKit05.Tid2(),
		}
		reload(packagekit)
		pk = packagekit.PackageKit()
		assert pk.available

		factory = Exception("not called")
		pk.get_candidates('gimp', factory, 'package:test')

		blocker = pk.fetch_candidates(["gimp"])
		h.wait_for_blocker(blocker)
		tasks.check(blocker)

		impls = {}
		def factory(impl_id, only_if_missing, installed):
			assert impl_id.startswith('package:')
			assert only_if_missing is True
			assert installed is False

			feed = None

			impl = model.DistributionImplementation(feed, impl_id, self)
			impl.installed = installed
			impls[impl_id] = impl
			return impl

		pk.get_candidates('gimp', factory, 'package:test')
		self.assertEquals(["package:test:gimp:2.6.8-2"], impls.keys())

if __name__ == '__main__':
	unittest.main()
