#!/usr/bin/env python
from basetest import BaseTest
import sys
import unittest

thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

sys.path.insert(0, '..')
from zeroinstall.injector import trust
from zeroinstall import SafeException

class TestTrust(BaseTest):
	def testInit(self):
		assert not trust.trust_db.is_trusted(thomas_fingerprint)
		assert not trust.trust_db.is_trusted("1234")
		assert len(trust.trust_db.keys) == 0

	def testDomain(self):
		self.assertEqual("example.com", trust.domain_from_url('http://example.com/foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('/tmp/feed.xml'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('http:///foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url('http://*/foo'))
		self.assertRaises(SafeException, lambda: trust.domain_from_url(''))


if __name__ == '__main__':
	unittest.main()
