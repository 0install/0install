#!/usr/bin/env python
from basetest import BaseTest, StringIO
import sys, tempfile, os
import unittest
import logging

logger = logging.getLogger()

sys.path.insert(0, '..')

from zeroinstall.zerostore import Store, manifest, BadDigest, cli, NotStored
from zeroinstall import SafeException, support

mydir = os.path.dirname(__file__)

class TestStore(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.store_parent = tempfile.mktemp()
		os.mkdir(self.store_parent, 0o700)
		self.store = Store(self.store_parent + '/implementations')
		os.mkdir(self.store.dir, 0o700)

		self.tmp = tempfile.mktemp()
		os.mkdir(self.tmp)
	
	def tearDown(self):
		BaseTest.tearDown(self)

		support.ro_rmtree(self.store_parent)
		support.ro_rmtree(self.tmp)

		cli.stores = None
	
	def testInit(self):
		assert os.path.isdir(self.store.dir)
		self.assertEqual([], os.listdir(self.store.dir))

	def testVerify(self):
		path = os.path.join(self.tmp, 'MyLink')
		os.symlink('Hello', path)
		mfile = os.path.join(self.tmp, '.manifest')
		for alg_name in ['sha1', 'sha256', 'sha1new', 'sha256new']:
			try:
				alg = manifest.get_algorithm(alg_name)
				added_digest = alg.getID(manifest.add_manifest_file(self.tmp, alg))
				digest = alg.new_digest()
				digest.update(b'Hello')
				with open(mfile, 'rb') as stream:
					self.assertEqual(("S %s 5 MyLink\n" % digest.hexdigest()).encode('utf-8'),
							stream.read())
				manifest.verify(self.tmp, added_digest)
				os.chmod(self.tmp, 0o700)
				os.unlink(mfile)
			except BadDigest as ex:
				raise Exception("%s: %s\n%s" % (alg_name, ex, ex.detail))
	
	def populate_sample(self, target):
		"""Create a set of files, links and directories in target for testing."""
		path = os.path.join(target, 'MyFile')
		f = open(path, 'w')
		f.write('Hello')
		f.close()
		os.utime(path, (1, 2))

		subdir = os.path.join(target, 'My Dir')
		os.mkdir(subdir)

		subfile = os.path.join(subdir, '!a file!')
		f = open(subfile, 'w')
		f.write('Some data.')
		f.close()
		os.utime(subfile, (1, 2))

		subfile += '.exe'
		f = open(subfile, 'w')
		f.write('Some code.')
		f.close()
		os.chmod(subfile, 0o500)
		os.utime(subfile, (1, 2))

		os.symlink('/the/symlink/target',
			   os.path.join(target, 'a symlink'))

	def testOptimise(self):
		sample = os.path.join(self.tmp, 'sample')
		os.mkdir(sample)
		self.populate_sample(sample)
		self.store.add_dir_to_cache('sha1new=7e3eb25a072988f164bae24d33af69c1814eb99a',
					   sample,
					   try_helper = False)
		subfile = os.path.join(sample, 'My Dir', '!a file!.exe')
		mtime = os.stat(subfile).st_mtime
		os.chmod(subfile, 0o755)
		stream = open(subfile, 'w')
		stream.write('Extra!\n')
		stream.close()
		os.utime(subfile, (mtime, mtime))
		self.store.add_dir_to_cache('sha1new=40861a33dba4e7c26d37505bd9693511808c0c35',
					   sample,
					   try_helper = False)

		impl_a = self.store.lookup('sha1new=7e3eb25a072988f164bae24d33af69c1814eb99a')
		impl_b = self.store.lookup('sha1new=40861a33dba4e7c26d37505bd9693511808c0c35')

		def same_inode(name):
			info_a = os.lstat(os.path.join(impl_a, name))
			info_b = os.lstat(os.path.join(impl_b, name))
			return info_a.st_ino == info_b.st_ino

		assert not same_inode('My Dir/!a file!')
		assert not same_inode('My Dir/!a file!.exe')

		old_stdout = sys.stdout
		sys.stdout = StringIO()
		try:
			cli.do_optimise([self.store.dir])
			got = sys.stdout.getvalue()
		finally:
			sys.stdout = old_stdout
		assert 'Space freed up : 15 bytes' in got

		old_stdout = sys.stdout
		sys.stdout = StringIO()
		try:
			cli.do_optimise([self.store.dir])
			got = sys.stdout.getvalue()
		finally:
			sys.stdout = old_stdout
		assert 'No duplicates found; no changes made.' in got

		assert same_inode('My Dir/!a file!')
		assert not same_inode('My Dir/!a file!.exe')
	
if __name__ == '__main__':
	unittest.main()
