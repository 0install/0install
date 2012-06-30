#!/usr/bin/env python
from basetest import BaseTest
import sys, tempfile
import unittest
import warnings

sys.path.insert(0, '..')
from zeroinstall.injector import gpg, model, trust

err_sig = b"""<?xml version="1.0" ?>
<?xml-stylesheet type='text/xsl' href='interface.xsl'?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>test</name>
  <summary>test</summary>
</interface>
<!-- Base64 Signature
iJwEAAECAAYFAk1NVyAACgkQerial32qo5eVCgP/RYEzT43M2Dj3winnkX2HQDO2Fx5dq83pmidd
LDEID3FxbuIpMUP/2rvPmNM3itRo/J4R2xkM65TEol/55uxDC1bbuarKf3wbgwEF60srFEDeeiYM
FmTQtWYPtrzAGtNRTgKfD75xk9lcM2GHmKNlgSQ7G8ZsfL6KaraF4Wa6nqU=

-->
"""

bad_xml_main = b"""<?xml version='1.0'?>
<root/>"""

invalid_xmls_sigs = [
('last line is not end-of-comment',
b"""<!-- Base64 Signature
"""),
('No signature block in XML',
b"""<!-- Base64 Sig
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
-->
"""),
('extra data on comment line',
b"""<!-- Base64 Signature data
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
-->
"""),
('last line is not end-of-comment',
b"""<!-- Base64 Signature
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
--> More
"""),
('Invalid base 64 encoded signature:',
b"""<!-- Base64 Signature
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
=zMc+
-->
"""),
('Invalid characters found',
b"""<!-- Base64 Signature
iD8DBQBDtpK9rge<CgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
-->
""")]

good_xml_sig = b"""<?xml version='1.0'?>
<root/>
<!-- Base64 Signature
iD8DBQBDuChIrgeCgFmlPMERAnGEAJ0ZS1PeyWonx6xS/mgpYTKNgSXa5QCeMSYPHhNcvxu3f84y
Uk7hxHFeQPo=
-->
"""

bad_xml_sig = b"""<?xml version='1.0'?>
<ro0t/>
<!-- Base64 Signature
iD8DBQBDuChIrgeCgFmlPMERAnGEAJ0ZS1PeyWonx6xS/mgpYTKNgSXa5QCeMSYPHhNcvxu3f84y
Uk7hxHFeQPo=
-->
"""

from data import thomas_key

THOMAS_FINGERPRINT = '92429807C9853C0744A68B9AAE07828059A53CC1'

class TestGPG(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(thomas_key)
			stream.seek(0)
			gpg.import_key(stream)
			trust.trust_db.trust_key(THOMAS_FINGERPRINT)
			warnings.filterwarnings("ignore", category = DeprecationWarning)
	
	def testImportBad(self):
		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(b"Bad key")
			stream.seek(0)
			try:
				gpg.import_key(stream)
				assert False
			except model.SafeException:
				pass	# OK

	def testErrSig(self):
		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(err_sig)
			stream.seek(0)
			data, sigs = gpg.check_stream(stream)
			self.assertEqual(err_sig, data.read())
			assert len(sigs) == 1
			assert isinstance(sigs[0], gpg.ErrSig)
			assert sigs[0].need_key() == "7AB89A977DAAA397"
			self.assertEqual("1", sigs[0].status[gpg.ErrSig.ALG])
			assert sigs[0].is_trusted() is False
			assert str(sigs[0]).startswith('ERROR')

	def testBadXMLSig(self):
		self.assertEqual(bad_xml_sig, self.check_bad(bad_xml_sig))

	def testInvalidXMLSig(self):
		for error, sig in invalid_xmls_sigs:
			try:
				self.check_bad(bad_xml_main + b'\n' + sig)
			except model.SafeException as ex:
				if error not in str(ex):
					raise model.SafeException(str(ex) + '\nSig:\n' + sig)

	def check_bad(self, sig):
		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(sig)
			stream.seek(0)
			data, sigs = gpg.check_stream(stream)
			assert len(sigs) == 1
			assert isinstance(sigs[0], gpg.BadSig)
			self.assertEqual("AE07828059A53CC1",
					  sigs[0].status[gpg.BadSig.KEYID])
			assert sigs[0].is_trusted() is False
			assert sigs[0].need_key() is None
			assert str(sigs[0]).startswith('BAD')
			return data.read()

	def testGoodXMLSig(self):
		self.assertEqual(good_xml_sig, self.check_good(good_xml_sig))
	
	def check_good(self, sig):
		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(sig)
			stream.seek(0)
			data, sigs = gpg.check_stream(stream)

			assert len(sigs) == 1
			assert isinstance(sigs[0], gpg.ValidSig)
			self.assertEqual("92429807C9853C0744A68B9AAE07828059A53CC1",
					  sigs[0].fingerprint)
			assert sigs[0].is_trusted() is True
			assert sigs[0].need_key() is None
			assert str(sigs[0]).startswith('Valid')
			for item in sigs[0].get_details():
				if item[0] == 'uid' and len(item) > 9:
					assert item[9] in ["Thomas Leonard <tal197@users.sourceforge.net>"], str(item)
					break
			else:
				self.fail("Missing name")
			return data.read()
	
	def testNoSig(self):
		with tempfile.TemporaryFile(mode = 'w+b') as stream:
			stream.write(b"Hello")
			stream.seek(0)
			try:
				gpg.check_stream(stream)
				assert False
			except model.SafeException:
				pass	# OK
	
	def testLoadKeys(self):
		self.assertEqual({}, gpg.load_keys([]))
		keys = gpg.load_keys([THOMAS_FINGERPRINT])
		self.assertEqual(1, len(keys))
		key = keys[THOMAS_FINGERPRINT]
		self.assertEqual(THOMAS_FINGERPRINT, key.fingerprint)
		self.assertEqual('Thomas Leonard <tal197@users.sourceforge.net>',
				key.name)

if __name__ == '__main__':
	unittest.main()
