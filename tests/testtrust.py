#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest

thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

sys.path.insert(0, '..')
from zeroinstall.injector import trust, basedir

class TestTrust(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		reload(basedir)

		assert basedir.xdg_config_home == self.config_home
		os.mkdir(self.config_home, 0700)
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
	
	def testInit(self):
		assert not trust.trust_db.is_trusted(thomas_fingerprint)
		assert not trust.trust_db.is_trusted("1234")
		assert len(trust.trust_db.keys) == 0

	def testAddInvalid(self):
		try:
			trust.trust_db.trust_key("hello")
			assert 0
		except ValueError:
			pass

	def testAdd(self):
		assert not trust.trust_db.is_trusted("1234")
		trust.trust_db.trust_key("1234")
		assert trust.trust_db.is_trusted("1234")
		assert not trust.trust_db.is_trusted("1236")

		trust.trust_db.untrust_key("1234")
		assert not trust.trust_db.is_trusted("1234")
	
	def testParallel(self):
		a = trust.TrustDB()
		b = trust.TrustDB()
		a.trust_key("1")
		assert b.is_trusted("1")
		b.trust_key("2")
		a.untrust_key("1")
		assert not a.is_trusted("1")
		assert a.is_trusted("2")

suite = unittest.makeSuite(TestTrust)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
