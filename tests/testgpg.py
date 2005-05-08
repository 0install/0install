#!/usr/bin/env python2.2
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

thomas_key = """-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.0.7 (GNU/Linux)

mQGiBD1JRcERBADIOjwNaBjmv44a3DPJeVwqrdVO6nuYF16UwKXTAh3ZZNAYecD8
a7opNf4yt3TofSKfT2bEiv/hIdAy3LGjKQg54Dou1EqhB8o90RNl5NeWmHIb82Jp
bCSbAXfaEaz6MEIg0MTHBcvtAOHZbKoBuBO5b6nbokmvcyWZXJHQ9zs9dwCg4FSX
cdVBExg+2iBzEzpGyK4EFrsEAKTxf2YoLGihB1HDknvlAWIfa5dBZI9c7pdbpmkW
6nZZ+SEHC9j1VSWFbB1fpA217BPaF6bmKmLoZEdmYLItriy2GEeEnbAcqd9QvQTr
RnXzBlOanC4OHqT0dvBLMH60TsWN2ZQQ3hPInI+CAdgquDzqoZY699moo+NXZZky
bB12A/9aI83jzl8gX7j61hkdk97rL/tcrdp8nGe2mS7y6tLodh89kp0IAD3Cn9pu
bQpEVMSIAO6ocMIMa6IhiSW+axKcW44JaOXtxFhLi9RDnGhds9LKPSB+Qoyfpxkk
zcAjNFcR2tDMOaDD5+/cZHSfKhT6TuWiiAzhhZEw3ikBnhCQYLQtVGhvbWFzIExl
b25hcmQgPHRhbDE5N0B1c2Vycy5zb3VyY2Vmb3JnZS5uZXQ+iFkEExECABkFAj1J
RcEECwcDAgMVAgMDFgIBAh4BAheAAAoJEK4HgoBZpTzBvdUAoMYjTfjeiOLyBF+V
6tm/8Da/VIS2AKDXlYeko8yY/DMZDy9uLrmlrOLYmrkBDQQ9SUXGEAQA40HXju3P
alvuv73gX0PcNC1lVTE3X15DTdvQLCCCt0H62A73i22c80CfGj3LaVybOHPjuM2/
phu69zf5S3wHFJXYzezkVO7Yf/0MRyQslviy/+pWdbBJnVaE+qF3wggvcHIddatd
roJ7q1haFl+cmIf43+EqoDZWVtKejSyeuGsAAwUEAOIrD9sPoing4huSDDgNJ9bo
DbG3YkT9GROZ2FMdz12pwjUvSSxa8Yh4zJQ1EkKprSCD7QZMu9FMudzuwHZweJN1
OhG+amFSsHmYl4Cbql9401lZvpvWoBhi54eKGMaxDNIGyojWJD8FTiC2eUrMwu3G
rXu8m0nbaNiXL88Kv6EHiEYEGBECAAYFAj1JRcYACgkQrgeCgFmlPMHF8ACfehcT
YkxNRG4ozQP5gwBO8CDdGVAAn0P7xyghEym4gcy7/rvwkY7JIar5
=wks3
-----END PGP PUBLIC KEY BLOCK-----
"""

gnupg_home = tempfile.mktemp()
os.environ['GNUPGHOME'] = gnupg_home

class TestGPG(unittest.TestCase):
	def setUp(self):
		os.mkdir(gnupg_home, 0700)
		stream = tempfile.TemporaryFile()
		stream.write(thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
	
	def tearDown(self):
		shutil.rmtree(gnupg_home)
	
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
				  sigs[0].status[gpg.ValidSig.FINGERPRINT])
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
