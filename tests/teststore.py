#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest
from logging import getLogger, DEBUG, INFO
#getLogger().setLevel(DEBUG)

sys.path.insert(0, '..')

from zeroinstall.zerostore import Store, manifest, BadDigest

class TestStore(unittest.TestCase):
	def setUp(self):
		path = tempfile.mktemp()
		os.mkdir(path, 0700)
		self.store = Store(path)

		self.tmp = tempfile.mktemp()
		os.mkdir(self.tmp)
	
	def tearDown(self):
		shutil.rmtree(self.store.dir)
		shutil.rmtree(self.tmp)
	
	def testInit(self):
		assert os.path.isdir(self.store.dir)
		self.assertEquals([], os.listdir(self.store.dir))

	def testEmptyManifest(self):
		lines = list(manifest.generate_manifest(self.tmp))
		self.assertEquals([], lines)

	def testSimpleManifest(self):
		path = os.path.join(self.tmp, 'MyFile')
		f = file(path, 'w')
		f.write('Hello')
		f.close()
		os.utime(path, (1, 2))
		lines = list(manifest.generate_manifest(self.tmp))
		self.assertEquals(['F f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 2 5 MyFile'],
				lines)

	def testLinkManifest(self):
		path = os.path.join(self.tmp, 'MyLink')
		os.symlink('Hello', path)
		lines = list(manifest.generate_manifest(self.tmp))
		self.assertEquals(['S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 MyLink'],
				lines)

	def testVerify(self):
		path = os.path.join(self.tmp, 'MyLink')
		os.symlink('Hello', path)
		mfile = os.path.join(self.tmp, '.manifest')
		for alg_name in ['sha1', 'sha256', 'sha1new']:
			try:
				alg = manifest.get_algorithm(alg_name)
				added_digest = alg.getID(manifest.add_manifest_file(self.tmp, alg))
				digest = alg.new_digest()
				digest.update('Hello')
				self.assertEquals("S %s 5 MyLink\n" % digest.hexdigest(),
						file(mfile).read())
				manifest.verify(self.tmp, added_digest)
				os.unlink(mfile)
			except BadDigest, ex:
				raise Exception(alg_name + ": " + str(ex) + "\n" + ex.detail)

suite = unittest.makeSuite(TestStore)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
