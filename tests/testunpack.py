#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile, os
import unittest, logging

sys.path.insert(0, '..')
from zeroinstall.zerostore import unpack, manifest, Store, BadDigest
from zeroinstall import SafeException, support

class AbstractTestUnpack(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.tmpdir = tempfile.mkdtemp('-testunpack')

		os.umask(0022)
	
	def tearDown(self):
		BaseTest.tearDown(self)

		support.ro_rmtree(self.tmpdir)

		assert os.umask(0022) == 0022
	
	def testBadExt(self):
		try:
			unpack.unpack_archive('ftp://foo/file.foo', file('HelloWorld.tgz'), self.tmpdir)
			assert False
		except SafeException, ex:
			assert 'Unknown extension' in str(ex)
	
	def testTgz(self):
		unpack.unpack_archive('ftp://foo/file.tgz', file('HelloWorld.tgz'), self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testZip(self):
		unpack.unpack_archive('ftp://foo/file.zip', file('HelloWorld.zip'), self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testExtract(self):
		unpack.unpack_archive('ftp://foo/file.tgz', file('HelloWorld.tgz'), self.tmpdir, extract = 'HelloWorld')
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testExtractZip(self):
		unpack.unpack_archive('ftp://foo/file.zip', file('HelloWorld.zip'), self.tmpdir, extract = 'HelloWorld')
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')

	def testExtractIllegal(self):
		try:
			unpack.unpack_archive('ftp://foo/file.tgz', file('HelloWorld.tgz'), self.tmpdir, extract = 'Hello`World`')
			assert False
		except SafeException, ex:
			assert 'Illegal' in str(ex)
	
	def testExtractFails(self):
		stderr = os.dup(2)
		try:
			null = os.open('/dev/null', os.O_WRONLY)
			os.close(2)
			os.dup2(null, 2)
			try:
				unpack.unpack_archive('ftp://foo/file.tgz', file('HelloWorld.tgz'), self.tmpdir, extract = 'HelloWorld2')
				assert False
			except SafeException, ex:
				if ('Failed to extract' not in str(ex) and	# GNU tar
				    'Unable to find' not in str(ex)):		# Python tar
					raise ex
		finally:
			os.dup2(stderr, 2)
	
	def testTargz(self):
		unpack.unpack_archive('ftp://foo/file.tar.GZ', file('HelloWorld.tgz'), self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testTbz(self):
		unpack.unpack_archive('ftp://foo/file.tar.bz2', file('HelloWorld.tar.bz2'), self.tmpdir)
		self.assert_manifest('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
	
	def testTar(self):
		unpack.unpack_archive('ftp://foo/file.tar', file('HelloWorld.tar'), self.tmpdir)
		self.assert_manifest('sha1new=290eb133e146635fe37713fd58174324a16d595f')
	
	def testRPM(self):
		unpack.unpack_archive('ftp://foo/file.rpm', file('dummy-1-1.noarch.rpm'), self.tmpdir)
		self.assert_manifest('sha1=7be9228c8fe2a1434d4d448c4cf130e3c8a4f53d')
	
	def testDeb(self):
		unpack.unpack_archive('ftp://foo/file.deb', file('dummy_1-1_all.deb'), self.tmpdir)
		self.assert_manifest('sha1new=2c725156ec3832b7980a3de2270b3d8d85d4e3ea')
	
	def testSpecial(self):
		os.chmod(self.tmpdir, 02755)
		store = Store(self.tmpdir)
		store.add_archive_to_cache('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a',
					   file('HelloWorld.tgz'),
					   'http://foo/foo.tgz')
	
	def testBad(self):
		logging.getLogger('').setLevel(logging.ERROR)

		store = Store(self.tmpdir)
		try:
			store.add_archive_to_cache('sha1=3ce644dc725f1d21cfcf02562c76f375944b266b',
						   file('HelloWorld.tgz'),
						   'http://foo/foo.tgz')
			assert 0
		except BadDigest:
			pass

		logging.getLogger('').setLevel(logging.INFO)

	def assert_manifest(self, required):
		alg_name = required.split('=', 1)[0]
		manifest.fixup_permissions(self.tmpdir)
		sha1 = alg_name + '=' + manifest.add_manifest_file(self.tmpdir, manifest.get_algorithm(alg_name)).hexdigest()
		self.assertEquals(sha1, required)

		# Check permissions are sensible
		for root, dirs, files in os.walk(self.tmpdir):
			for f in files + dirs:
				full = os.path.join(root, f)
				if os.path.islink(full): continue
				full_mode = os.stat(full).st_mode
				self.assertEquals(0444, full_mode & 0666)	# Must be r-?r-?r-?

class TestUnpackPython(AbstractTestUnpack):
	def setUp(self):
		AbstractTestUnpack.setUp(self)
		unpack._tar_version = 'Solaris tar'
		assert not unpack._gnu_tar()

class TestUnpackGNU(AbstractTestUnpack):
	def setUp(self):
		AbstractTestUnpack.setUp(self)
		unpack._tar_version = None
		assert unpack._gnu_tar()

	# Only available with GNU tar
	def testLzma(self):
		unpack.unpack_archive('ftp://foo/file.tar.lzma', file('HelloWorld.tar.lzma'), self.tmpdir)
		self.assert_manifest('sha1new=290eb133e146635fe37713fd58174324a16d595f')

suite = unittest.TestSuite()
if unpack._gnu_tar():
	suite.addTest(unittest.makeSuite(TestUnpackGNU))
else:
	print "No GNU tar: SKIPPING tests"
suite.addTest(unittest.makeSuite(TestUnpackPython))

if __name__ == '__main__':
	unittest.TextTestRunner(verbosity=2).run(suite)
