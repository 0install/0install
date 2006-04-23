#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')
from zeroinstall.zerostore import manifest, BadDigest

class TestManifest(unittest.TestCase):
	def setUp(self):
		self.tmpdir = tempfile.mkdtemp(prefix = 'test-manifest')

	def tearDown(self):	
		shutil.rmtree(self.tmpdir)

	def testUnknownAlgorithm(self):
		try:
			manifest.get_algorithm('unknown')
			assert false
		except BadDigest:
			pass
	
	def testEmpty(self):
		self.assertEquals('',
			'\n'.join(manifest.generate_manifest(self.tmpdir)))
	
	def write(self, path, contents, time = None):
		assert not path.startswith('/')
		myfile = os.path.join(self.tmpdir, path)
		stream = file(myfile, 'w')
		stream.write(contents)
		stream.close()
		if time is not None:
			os.utime(myfile, (time, time))
		return myfile
	
	def testOldSHA(self):
		mydir = os.path.join(self.tmpdir, 'MyDir')
		os.mkdir(mydir)
		myfile = self.write('MyDir/Hello', 'Hello World', 30)
		myexec = self.write('MyDir/Run me', 'Bang!', 40)
		os.symlink('Hello', os.path.join(self.tmpdir, 'MyDir/Sym link'))
		os.chmod(myexec, 0700)
		os.utime(mydir, (10, 20))
		self.assertEquals([
			'D 20 /MyDir',
			'F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello',
			'X 4001b8c42ddfb61c453d04930e8ce78fb3a40bc8 40 5 Run me',
			'S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 Sym link'],
			list(manifest.generate_manifest(self.tmpdir)))

	def testNewSHA1(self):
		mydir = os.path.join(self.tmpdir, 'MyDir')
		os.mkdir(mydir)
		myfile = self.write('MyDir/Hello', 'Hello World', 30)
		myexec = self.write('MyDir/Run me', 'Bang!', 40)
		os.symlink('Hello', os.path.join(self.tmpdir, 'MyDir/Sym link'))
		os.chmod(myexec, 0700)
		os.utime(mydir, (10, 20))
		self.assertEquals([
			'D /MyDir',
			'F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello',
			'X 4001b8c42ddfb61c453d04930e8ce78fb3a40bc8 40 5 Run me',
			'S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 Sym link'],
			list(manifest.generate_manifest(self.tmpdir, alg = 'sha1new')))

	def testOrderingSHA1(self):
		mydir = os.path.join(self.tmpdir, 'Dir')
		os.mkdir(mydir)
		myfile = self.write('Hello', 'Hello World', 30)
		myfile = self.write('Dir/Hello', 'Hello World', 30)
		os.utime(mydir, (10, 20))
		self.assertEquals([
			'F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello',
			'D /Dir',
			'F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello'],
			list(manifest.generate_manifest(self.tmpdir, alg = 'sha1new')))

	def testNewSHA256(self):
		mydir = os.path.join(self.tmpdir, 'MyDir')
		os.mkdir(mydir)
		myfile = self.write('MyDir/Hello', 'Hello World', 30)
		myexec = self.write('MyDir/Run me', 'Bang!', 40)
		os.symlink('Hello', os.path.join(self.tmpdir, 'MyDir/Sym link'))
		os.chmod(myexec, 0700)
		self.assertEquals([
			'D /MyDir',
			'F a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e 30 11 Hello',
			'X 640628586b08f8ed3910bd1e75ba02818959e843b54efafb9c2260a1f77e3ddf 40 5 Run me',
			'S 185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969 5 Sym link'],
			list(manifest.generate_manifest(self.tmpdir, alg = 'sha256')))

	def testOrdering(self):
		mydir = os.path.join(self.tmpdir, 'Dir')
		os.mkdir(mydir)
		myfile = self.write('Hello', 'Hello World', 30)
		os.utime(mydir, (10, 20))
		self.assertEquals([
			'F a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e 30 11 Hello',
			'D /Dir'],
			list(manifest.generate_manifest(self.tmpdir, alg='sha256')))

suite = unittest.makeSuite(TestManifest)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
