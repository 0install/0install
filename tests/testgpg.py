#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import gpg, model

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

from data import thomas_key

class TestGPG(unittest.TestCase):
	def setUp(self):
		self.gnupg_home = tempfile.mktemp()
		os.environ['GNUPGHOME'] = self.gnupg_home
		os.mkdir(self.gnupg_home, 0700)
		stream = tempfile.TemporaryFile()
		stream.write(thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
	
	def tearDown(self):
		shutil.rmtree(self.gnupg_home)
	
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
		stream = tempfile.TemporaryFile()
		stream.write(bad_sig)
		stream.seek(0)
		data, sigs = gpg.check_stream(stream)
		self.assertEquals("Hell0\n", data.read())
		assert len(sigs) == 1
		assert isinstance(sigs[0], gpg.BadSig)
		self.assertEquals("AE07828059A53CC1",
				  sigs[0].status[gpg.BadSig.KEYID])
		assert sigs[0].is_trusted() is False
		assert sigs[0].need_key() is None
		assert str(sigs[0]).startswith('BAD')

	def testGoodSig(self):
		stream = tempfile.TemporaryFile()
		stream.write(good_sig)
		stream.seek(0)
		data, sigs = gpg.check_stream(stream)
		self.assertEquals("Hello\n", data.read())
		assert len(sigs) == 1
		assert isinstance(sigs[0], gpg.ValidSig)
		self.assertEquals("92429807C9853C0744A68B9AAE07828059A53CC1",
				  sigs[0].fingerprint)
		assert sigs[0].is_trusted() is True
		assert sigs[0].need_key() is None
		assert str(sigs[0]).startswith('Valid')
	
	def testNoSig(self):
		stream = tempfile.TemporaryFile()
		stream.write("Hello")
		stream.seek(0)
		try:
			gpg.check_stream(stream)
			assert False
		except model.SafeException:
			pass	# OK

suite = unittest.makeSuite(TestGPG)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
