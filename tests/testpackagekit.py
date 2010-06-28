#!/usr/bin/env python
from basetest import BaseTest
import sys
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import packagekit

class TestPackageKit(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		self.my_dbus = None

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

if __name__ == '__main__':
	unittest.main()
