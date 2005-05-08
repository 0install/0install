#!/usr/bin/env python2.2
import sys, tempfile
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import gpg

err_sig = """-----BEGIN PGP MESSAGE-----
Version: GnuPG v1.4.0 (GNU/Linux)

owGbwMvMwCTYk9R5Infvsj7G01xJDE513j1OiSlcHfbMrCDOBJisINP6XQwLGjzn
tMxedXc3y75I7r1hQZFTb/ewMcx3yefZ8zb/vZd10I7LEYdDj4fnKsYAAA==
=kMeU
-----END PGP MESSAGE-----
"""

class TestGPG(unittest.TestCase):
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

sys.argv.append('-v')
unittest.main()
