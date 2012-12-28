#!/usr/bin/env python
from basetest import BaseTest
import sys, imp
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import packagekit, model, fetch
from zeroinstall.support import tasks

import dbus

class Connection:
	def remove(self):
		pass

def makeFakePackageKit(version):
	class FakePackageKit:
		x = 0

		def GetTid(self):
			self.x += 1
			return "/tid/%d" % self.x

		class Tid:
			def __init__(self):
				self.signals = {}

			def connect_to_signal(self, signal, cb):
				self.signals[signal] = cb
				return Connection()

			def get_dbus_method(self, method):
				if hasattr(self, method):
					return getattr(self, method)
				raise dbus.exceptions.DBusException('org.freedesktop.DBus.Error.UnknownMethod')

			if version == '0.5':
				def SetLocale(self, locale):
					pass
			else:
				def SetHints(self, hints):
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

		class Install(Tid):
			def GetProgress(self):
				# %task, %sub-task, time-task, time-sub-task
				return (50, 101, 351, 0)

			def InstallPackages(self, arg1, arg2 = None):
				if version == '0.5':
					if arg2 is None:
						# newer 2-arg form
						raise dbus.exceptions.DBusException('org.freedesktop.DBus.Error.UnknownMethod')
					only_trusted = arg1
					package_ids = arg2
				else:
					assert version == '0.6'
					if arg2 is not None:
						# older 3-arg form
						raise dbus.exceptions.DBusException('org.freedesktop.DBus.Error.UnknownMethod')
					only_trusted = False
					package_ids = arg1

				assert only_trusted == False
				@tasks.async
				def later():
					yield
					for package_id in package_ids:
						assert package_id == "gimp;2.6.8-2ubuntu1.1;amd64;Ubuntu"
						self.signals['StatusChanged']("setup")

						# Unknown % for task and subtask
						# 0s time used so far
						#self.signals['ProgressChanged'](101, 101, 0, 0)

						yield

						#self.signals['ProgressChanged'](50, 101, 351, 0)

						#self.signals['AllowCancel'](False)
						self.signals['Package']("installing", "gimp;2.6.8-2ubuntu1.1;amd64;Ubuntu", "Graphics package")

						yield

						#self.signals['ProgressChanged'](100, 101, 1351, 0)
						self.signals['Package']("finished", "gimp;2.6.8-2ubuntu1.1;amd64;Ubuntu", "Graphics package")

					yield
					self.signals['Finished']("success", 100)
				later()
	return FakePackageKit()

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

			imp.reload(packagekit)

			pk = packagekit.PackageKit()
			assert pk.available == False

			factory = Exception("not called")
			pk.get_candidates('gimp', factory, 'package:null')
		finally:
			self.meta_path = []
			sys.modules['dbus'] = old_dbus

	def testNoPackageKit(self):
		imp.reload(packagekit)
		pk = packagekit.PackageKit()
		assert not pk.available

		factory = Exception("not called")
		pk.get_candidates('gimp', factory, 'package:null')

	def testPackageKit(self):
		#import logging
		#_logger_pk = logging.getLogger('0install.packagekit')
		#_logger_pk.setLevel(logging.DEBUG)

		for version in ['0.5', '0.6']:
			#print(version)
			pk = makeFakePackageKit(version)

			dbus.system_services['org.freedesktop.PackageKit'] = {
				'/org/freedesktop/PackageKit': pk,
				'/tid/1': pk.Tid1(),
				'/tid/2': pk.Tid2(),
				'/tid/3': pk.Install(),
			}
			self.doTest()
			self.assertEqual(3, pk.x)

	def doTest(self):
		imp.reload(packagekit)
		pk = packagekit.PackageKit()
		assert pk.available

		# Check none is found yet
		factory = Exception("not called")
		pk.get_candidates('gimp', factory, 'package:test')

		blocker = pk.fetch_candidates(["gimp"])
		blocker2 = pk.fetch_candidates(["gimp"])		# Check batching too

		@tasks.async
		def wait():
			yield blocker, blocker2
			if blocker.happened:
				tasks.check(blocker)
			else:
				tasks.check(blocker2)
		tasks.wait_for_blocker(wait())

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
		self.assertEqual(["package:test:gimp:2.6.8-2:x86_64"], list(impls.keys()))
		self.assertEqual(False, list(impls.values())[0].installed)

		impl, = impls.values()
		fetcher = fetch.Fetcher(config = self.config)
		self.config.handler.allow_downloads = True
		b = fetcher.download_impl(impl, impl.download_sources[0], stores = None)
		tasks.wait_for_blocker(b)
		tasks.check(b)
		self.assertEqual("/usr/bin/fixed", list(impls.values())[0].main)

		tasks.wait_for_blocker(blocker)
		tasks.wait_for_blocker(blocker2)

		# Don't fetch it again
		tasks.wait_for_blocker(pk.fetch_candidates(["gimp"]))

	def installed_fixup(self, impl):
		impl.main = '/usr/bin/fixed'

if __name__ == '__main__':
	unittest.main()
