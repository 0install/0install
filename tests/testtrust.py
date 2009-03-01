#!/usr/bin/env python2.5
from basetest import BaseTest
import sys
import unittest

thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

sys.path.insert(0, '..')
from zeroinstall.injector import trust
from zeroinstall import SafeException

class TestTrust(BaseTest):
	def testInit(self):
		trust.trust_db.untrust_key(thomas_fingerprint, domain = '0install.net')	# Gets added by default
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
	
	def testAddDomain(self):
		assert not trust.trust_db.is_trusted("1234", "0install.net")
		trust.trust_db.trust_key("1234")
		self.assertEquals(set(['*']), trust.trust_db.get_trust_domains("1234"))
		self.assertEquals(set(['1234']), trust.trust_db.get_keys_for_domain("*"))
		self.assertEquals(set(), trust.trust_db.get_trust_domains("bob"))

		assert trust.trust_db.is_trusted("1234")
		assert trust.trust_db.is_trusted("1234", "0install.net")
		assert trust.trust_db.is_trusted("1234", "rox.sourceforge.net")
		assert not trust.trust_db.is_trusted("1236")

		trust.trust_db.untrust_key("1234")
		assert not trust.trust_db.is_trusted("1234")
		assert not trust.trust_db.is_trusted("1234", "rox.sourceforge.net")

		trust.trust_db.trust_key("1234", "0install.net")
		trust.trust_db.trust_key("1234", "gimp.org")
		trust.trust_db.trust_key("1236", "gimp.org")
		assert trust.trust_db.is_trusted("1234")
		assert trust.trust_db.is_trusted("1234", "0install.net")
		assert trust.trust_db.is_trusted("1234", "gimp.org")
		assert not trust.trust_db.is_trusted("1234", "rox.sourceforge.net")

		self.assertEquals(set(['1234', '1236']),
			trust.trust_db.get_keys_for_domain("gimp.org"))

		self.assertEquals(set(), trust.trust_db.get_trust_domains("99877"))
		self.assertEquals(set(['0install.net', 'gimp.org']), trust.trust_db.get_trust_domains("1234"))
	
	def testParallel(self):
		a = trust.TrustDB()
		b = trust.TrustDB()
		a.trust_key("1")
		assert b.is_trusted("1")
		b.trust_key("2")
		a.untrust_key("1")
		assert not a.is_trusted("1")
		assert a.is_trusted("2")
	
	def testDomain(self):
		self.assertEquals("example.com", trust.domain_from_url('http://example.com/foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('/tmp/feed.xml'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('http:///foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('http://*/foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url(''))


suite = unittest.makeSuite(TestTrust)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
