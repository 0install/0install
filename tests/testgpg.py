#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import gpg, model, trust

err_sig = """-----BEGIN PGP MESSAGE-----
Version: GnuPG v1.4.0 (GNU/Linux)

owGbwMvMwCTYk9R5Infvsj7G01xJDE513j1OiSlcHfbMrCDOBJisINP6XQwLGjzn
tMxedXc3y75I7r1hQZFTb/ewMcx3yefZ8zb/vZd10I7LEYdDj4fnKsYAAA==
=kMeU
-----END PGP MESSAGE-----
"""

bad_sig = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA1

Hell0
-----BEGIN PGP SIGNATURE-----
Version: GnuPG v1.4.0 (GNU/Linux)

iD8DBQFCfk3grgeCgFmlPMERAhl8AKC0aktrLzz646zTY0TRzdnxPdbLBgCeJWbk
GRVbJusevCKvtoSn7RAW2mg=
=xQJ5
-----END PGP SIGNATURE-----
"""

good_sig = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA1

Hello
-----BEGIN PGP SIGNATURE-----
Version: GnuPG v1.4.0 (GNU/Linux)

iD8DBQFCfk3grgeCgFmlPMERAhl8AKC0aktrLzz646zTY0TRzdnxPdbLBgCeJWbk
GRVbJusevCKvtoSn7RAW2mg=
=xQJ5
-----END PGP SIGNATURE-----
"""

bad_xml_main = """<?xml version='1.0'?>
<root/>"""

invalid_xmls_sigs = [
('last line is not end-of-comment',
"""<!-- Base64 Signature
"""),
('No signature block in XML',
"""<!-- Base64 Sig
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
-->
"""),
('extra data on comment line',
"""<!-- Base64 Signature data
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
-->
"""),
('last line is not end-of-comment',
"""<!-- Base64 Signature
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
--> More
"""),
('Invalid base 64 encoded signature:',
"""<!-- Base64 Signature
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
=zMc+
-->
"""),
('Invalid characters found',
"""<!-- Base64 Signature
iD8DBQBDtpK9rge<CgFmlPMERAg0gAKCaJhXFnk
WZRBLT0an56WYaBODukSsf4=
-->
""")]

good_xml_sig = """<?xml version='1.0'?>
<root/>
<!-- Base64 Signature
iD8DBQBDuChIrgeCgFmlPMERAnGEAJ0ZS1PeyWonx6xS/mgpYTKNgSXa5QCeMSYPHhNcvxu3f84y
Uk7hxHFeQPo=
-->
"""

bad_xml_sig = """<?xml version='1.0'?>
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

		stream = tempfile.TemporaryFile()
		stream.write(thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		trust.trust_db.trust_key(THOMAS_FINGERPRINT)
	
	def testImportBad(self):
		stream = tempfile.TemporaryFile()
		stream.write("Bad key")
		stream.seek(0)
		try:
			gpg.import_key(stream)
			assert False
		except model.SafeException:
			pass	# OK

	def testErrSig(self):
		stream = tempfile.TemporaryFile()
		stream.write(err_sig)
		stream.seek(0)
		data, sigs = gpg.check_stream(stream)
		self.assertEquals("Bad\n", data.read())
		assert len(sigs) == 1
		assert isinstance(sigs[0], gpg.ErrSig)
		assert sigs[0].need_key() == "8C6289C86DBDA68E"
		self.assertEquals("17", sigs[0].status[gpg.ErrSig.ALG])
		assert sigs[0].is_trusted() is False
		assert str(sigs[0]).startswith('ERROR')

	def testBadSig(self):
		self.assertEquals("Hell0\n", self.check_bad(bad_sig))

	def testBadXMLSig(self):
		self.assertEquals(bad_xml_sig, self.check_bad(bad_xml_sig))

	def testInvalidXMLSig(self):
		for error, sig in invalid_xmls_sigs:
			try:
				self.check_bad(bad_xml_main + '\n' + sig)
			except model.SafeException, ex:
				if error not in str(ex):
					raise model.SafeException(str(ex) + '\nSig:\n' + sig)

	def check_bad(self, sig):
		stream = tempfile.TemporaryFile()
		stream.write(sig)
		stream.seek(0)
		data, sigs = gpg.check_stream(stream)
		assert len(sigs) == 1
		assert isinstance(sigs[0], gpg.BadSig)
		self.assertEquals("AE07828059A53CC1",
				  sigs[0].status[gpg.BadSig.KEYID])
		assert sigs[0].is_trusted() is False
		assert sigs[0].need_key() is None
		assert str(sigs[0]).startswith('BAD')
		return data.read()

	def testGoodSig(self):
		self.assertEquals("Hello\n", self.check_good(good_sig))

	def testGoodXMLSig(self):
		self.assertEquals(good_xml_sig, self.check_good(good_xml_sig))
	
	def check_good(self, sig):
		stream = tempfile.TemporaryFile()
		stream.write(sig)
		stream.seek(0)
		data, sigs = gpg.check_stream(stream)
		assert len(sigs) == 1
		assert isinstance(sigs[0], gpg.ValidSig)
		self.assertEquals("92429807C9853C0744A68B9AAE07828059A53CC1",
				  sigs[0].fingerprint)
		assert sigs[0].is_trusted() is True
		assert sigs[0].need_key() is None
		assert str(sigs[0]).startswith('Valid')
		for item in sigs[0].get_details():
			if item[0] in ('pub', 'uid') and len(item) > 9:
				self.assertEquals(
					"Thomas Leonard <tal197@users.sourceforge.net>",
					item[9])
				break
		else:
			self.fail("Missing name")
		return data.read()
	
	def testNoSig(self):
		stream = tempfile.TemporaryFile()
		stream.write("Hello")
		stream.seek(0)
		try:
			gpg.check_stream(stream)
			assert False
		except model.SafeException:
			pass	# OK
	
	def testLoadKeys(self):

		self.assertEquals({}, gpg.load_keys([]))
		keys = gpg.load_keys([THOMAS_FINGERPRINT])
		self.assertEquals(1, len(keys))
		key = keys[THOMAS_FINGERPRINT]
		self.assertEquals(THOMAS_FINGERPRINT, key.fingerprint)
		self.assertEquals('Thomas Leonard <tal197@users.sourceforge.net>',
				key.name)

suite = unittest.makeSuite(TestGPG)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
