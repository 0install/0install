#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile, os
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall.zerostore import Store, manifest, BadDigest, cli
from zeroinstall import SafeException, support

class TestStore(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.store_parent = tempfile.mktemp()
		os.mkdir(self.store_parent, 0700)
		self.store = Store(self.store_parent + '/implementations')
		os.mkdir(self.store.dir, 0700)

		self.tmp = tempfile.mktemp()
		os.mkdir(self.tmp)
	
	def tearDown(self):
		BaseTest.tearDown(self)

		support.ro_rmtree(self.store_parent)
		support.ro_rmtree(self.tmp)
	
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
				os.chmod(self.tmp, 0700)
				os.unlink(mfile)
			except BadDigest, ex:
				raise Exception("%s: %s\n%s" % (alg_name, ex, ex.detail))
	
	def populate_sample(self, target):
		"""Create a set of files, links and directories in target for testing."""
		path = os.path.join(target, 'MyFile')
		f = file(path, 'w')
		f.write('Hello')
		f.close()
		os.utime(path, (1, 2))

		subdir = os.path.join(target, 'My Dir')
		os.mkdir(subdir)

		subfile = os.path.join(subdir, '!a file!')
		f = file(subfile, 'w')
		f.write('Some data.')
		f.close()
		os.utime(subfile, (1, 2))

		subfile += '.exe'
		f = file(subfile, 'w')
		f.write('Some code.')
		f.close()
		os.chmod(subfile, 0500)
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
		os.chmod(subfile, 0755)
		stream = file(subfile, 'w')
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
	
	def testCopy(self):
		sha1 = manifest.get_algorithm('sha1')
		sha1new = manifest.get_algorithm('sha1new')
		source = os.path.join(self.tmp, 'badname')
		os.mkdir(source)

		self.populate_sample(source)

		lines = list(sha1new.generate_manifest(source))
		self.assertEquals(['F f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 2 5 MyFile',
				   'S 570b0ce957ab43e774c82fca0ea3873fc452278b 19 a symlink',
				   'D /My Dir',
				   'F 0236ef92e1e37c57f0eb161e7e2f8b6a8face705 2 10 !a file!',
				   'X b4ab02f2c791596a980fd35f51f5d92ee0b4705c 2 10 !a file!.exe'],
				lines)
		digest = sha1.getID(manifest.add_manifest_file(source, sha1))

		copy = tempfile.mktemp()
		os.mkdir(copy)
		try:
			# Source must be in the form alg=value
			try:
				cli.do_copy([source, copy])
				assert 0
			except BadDigest, ex:
				assert 'badname' in str(ex)
			source, badname = os.path.join(self.tmp, digest), source
			os.rename(badname, source)

			# Can't copy sha1 implementations (unsafe)
			try:
				cli.do_copy([source, copy])
			except SafeException, ex:
				assert 'sha1' in str(ex)

			# Already have a .manifest
			try:
				manifest.add_manifest_file(source, sha1new)
				assert 0
			except SafeException, ex:
				assert '.manifest' in str(ex)

			os.chmod(source, 0700)
			os.unlink(os.path.join(source, '.manifest'))

			# Switch to sha1new
			digest = sha1new.getID(manifest.add_manifest_file(source, sha1new))
			source, badname = os.path.join(self.tmp, digest), source
			os.rename(badname, source)

			cli.do_copy([source, copy])

			self.assertEquals('Hello', file(os.path.join(copy, digest, 'MyFile')).read())
		finally:
			support.ro_rmtree(copy)

suite = unittest.makeSuite(TestStore)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
