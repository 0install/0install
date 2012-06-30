#!/usr/bin/env python

from __future__ import print_function

from basetest import BaseTest
import sys, tempfile, os
import unittest, logging

sys.path.insert(0, '..')
from zeroinstall.zerostore import unpack, manifest, Store, BadDigest
from zeroinstall import SafeException, support
from zeroinstall.support import find_in_path

def skipIf(condition, reason):
	def wrapped(underlying):
		if condition:
			if hasattr(underlying, 'func_name'):
				print("Skipped %s: %s" % (underlying.func_name, reason))	# Python 2
			else:
				print("Skipped %s: %s" % (underlying.__name__, reason))		# Python 3
			def run(self): pass
			return run
		else:
			return underlying
	return wrapped

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
	
	def testExtractOver(self):
		with open('HelloWorld.tgz', 'rb') as stream:
			unpack.unpack_archive_over('ftp://foo/file.tgz', stream, self.tmpdir, extract = 'HelloWorld')
		self.assert_manifest('sha1=491678c37f77fadafbaae66b13d48d237773a68f')

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

	def testSpecial(self):
		os.chmod(self.tmpdir, 0o2755)
		store = Store(self.tmpdir)
		with open('HelloWorld.tgz', 'rb') as stream:
			store.add_archive_to_cache('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a',
						   stream,
						   'http://foo/foo.tgz')
	
	def testBad(self):
		logging.getLogger('').setLevel(logging.ERROR)

		store = Store(self.tmpdir)
		try:
			with open('HelloWorld.tgz', 'rb') as stream:
				store.add_archive_to_cache('sha1=3ce644dc725f1d21cfcf02562c76f375944b266b',
							   stream,
							   'http://foo/foo.tgz')
			assert 0
		except BadDigest:
			pass

		logging.getLogger('').setLevel(logging.INFO)

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
