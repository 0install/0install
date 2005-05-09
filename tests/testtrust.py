#!/usr/bin/env python2.2
import sys, tempfile, os, shutil
import unittest

config_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home

thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

sys.path.insert(0, '..')
from zeroinstall.injector import trust, basedir

reload(basedir)

class TestTrust(unittest.TestCase):
	def setUp(self):
		assert basedir.xdg_config_home == config_home
		os.mkdir(config_home, 0700)
	
	def tearDown(self):
		shutil.rmtree(config_home)
	
	def testInit(self):
		assert trust.trust_db.is_trusted(thomas_fingerprint)
		assert not trust.trust_db.is_trusted("1234")
		assert len(trust.trust_db.keys) == 1

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
