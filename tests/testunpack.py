#!/usr/bin/env python

from __future__ import print_function

from basetest import BaseTest, skipIf
import sys, tempfile, os
import unittest, logging

sys.path.insert(0, '..')
from zeroinstall.zerostore import unpack, manifest, Store, BadDigest
from zeroinstall import SafeException, support
from zeroinstall.support import find_in_path

class AbstractTestUnpack():
	def setUp(self):
		BaseTest.setUp(self)

		self.tmpdir = tempfile.mkdtemp('-testunpack')

		os.umask(0o022)
	
	def tearDown(self):
		BaseTest.tearDown(self)

		support.ro_rmtree(self.tmpdir)

		assert os.umask(0o022) == 0o022
	
	def testBadExt(self):
		try:
			with open('HelloWorld.tgz', 'rb') as stream:
				unpack.unpack_archive('ftp://foo/file.foo', stream, self.tmpdir)
			assert False
		except SafeException as ex:
			assert 'Unknown extension' in str(ex)
	
	def testTgz(self):
		with open('HelloWorld.tgz', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')

	@skipIf(sys.getfilesystemencoding().lower() != "utf-8", "tar only unpacks to utf-8")
	def testNonAsciiTgz(self):
		with open('unicode.tar.gz', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir)
		self.assert_manifest('sha1new=e42ffed02179169ef2fa14a46b0d9aea96a60c10')
	
	@skipIf(not find_in_path('hdiutil'), "not running on MacOS X; no hdiutil")
	def testDmg(self):
		with open('HelloWorld.dmg', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.dmg', stream, self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testZip(self):
		with open('HelloWorld.zip', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.zip', stream, self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testExtract(self):
		with open('HelloWorld.tgz', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir, extract = 'HelloWorld')
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')

	@skipIf(sys.getfilesystemencoding().lower() != "utf-8", "tar only unpacks to utf-8")
	def testExtractNonAscii(self):
		with open('unicode.tar.gz', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir, extract= b'unicode'.decode('ascii'))
		self.assert_manifest('sha1=af2d132f5f15532bbf041b59414d08c8bc1a616e')
	
	def testExtractZip(self):
		with open('HelloWorld.zip', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.zip', stream, self.tmpdir, extract = 'HelloWorld')
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')

	def testExtractIllegal(self):
		try:
			with open('HelloWorld.tgz', 'rb') as stream:
				unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir, extract = 'Hello`World`')
			assert False
		except SafeException as ex:
			assert 'Illegal' in str(ex)
	
	def testExtractFails(self):
		stderr = os.dup(2)
		try:
			null = os.open(os.devnull, os.O_WRONLY)
			os.close(2)
			os.dup2(null, 2)
			try:
				with open('HelloWorld.tgz', 'rb') as stream:
					unpack.unpack_archive('ftp://foo/file.tgz', stream, self.tmpdir, extract = 'HelloWorld2')
				assert False
			except SafeException as ex:
				if ('Failed to extract' not in str(ex) and	# GNU tar
				    'Unable to find' not in str(ex)):		# Python tar
					raise ex
		finally:
			os.dup2(stderr, 2)
	
	def testTargz(self):
		with open('HelloWorld.tgz', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tar.GZ', stream, self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testTbz(self):
		with open('HelloWorld.tar.bz2', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tar.bz2', stream, self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testTar(self):
		with open('HelloWorld.tar', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tar', stream, self.tmpdir)
		self.assert_manifest('sha1new=290eb133e146635fe37713fd58174324a16d595f')
	
	@skipIf(not find_in_path('rpm2cpio'), "not running; no rpm2cpio")
	def testRPM(self):
		with open('dummy-1-1.noarch.rpm', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.rpm', stream, self.tmpdir)
		self.assert_manifest('sha1=7be9228c8fe2a1434d4d448c4cf130e3c8a4f53d')
	
	def testDeb(self):
		with open('dummy_1-1_all.deb', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.deb', stream, self.tmpdir)
		self.assert_manifest('sha1new=2c725156ec3832b7980a3de2270b3d8d85d4e3ea')
	
	def testGem(self):
		with open('hello-0.1.gem', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.gem', stream, self.tmpdir)
		self.assert_manifest('sha1new=fbd4827be7a18f9821790bdfd83132ee60d54647')

	def assert_manifest(self, required):
		alg_name = required.split('=', 1)[0]
		manifest.fixup_permissions(self.tmpdir)

		sha1 = alg_name + '=' + manifest.add_manifest_file(self.tmpdir, manifest.get_algorithm(alg_name)).hexdigest()
		self.assertEqual(sha1, required)

		# Check permissions are sensible
		for root, dirs, files in os.walk(self.tmpdir):
			for f in files + dirs:
				full = os.path.join(root, f)
				if os.path.islink(full): continue
				full_mode = os.stat(full).st_mode
				self.assertEqual(0o444, full_mode & 0o666)	# Must be r-?r-?r-?

class TestUnpackPython(AbstractTestUnpack, BaseTest):
	def setUp(self):
		AbstractTestUnpack.setUp(self)
		unpack._tar_version = 'Solaris tar'
		assert not unpack._gnu_tar()

class TestUnpackGNU(AbstractTestUnpack, BaseTest):
	def setUp(self):
		AbstractTestUnpack.setUp(self)
		unpack._tar_version = None
		assert unpack._gnu_tar()

	# Only available with GNU tar
	def testLzma(self):
		with open('HelloWorld.tar.lzma', 'rb') as stream:
			unpack.unpack_archive('ftp://foo/file.tar.lzma', stream, self.tmpdir)
		self.assert_manifest('sha1new=290eb133e146635fe37713fd58174324a16d595f')

if not unpack._gnu_tar():
	print("No GNU tar: SKIPPING tests")
	del globals()['TestUnpackGNU']

if __name__ == '__main__':
	unittest.main()
