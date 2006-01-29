import os
import shutil
import traceback
from tempfile import mkdtemp, mkstemp
import sha
import re
from logging import debug, info, warn

import manifest
from zeroinstall.injector import basedir
from zeroinstall import SafeException

class BadDigest(SafeException): pass
class NotStored(SafeException): pass

def copytree2(src, dst):
	names = os.listdir(src)
	assert os.path.isdir(dst)
	errors = []
	for name in names:
		srcname = os.path.join(src, name)
		dstname = os.path.join(dst, name)
		if os.path.islink(srcname):
			linkto = os.readlink(srcname)
			os.symlink(linkto, dstname)
		elif os.path.isdir(srcname):
			os.mkdir(dstname)
			mtime = os.lstat(srcname).st_mtime
			copytree2(srcname, dstname)
			os.utime(dstname, (mtime, mtime))
		else:
			shutil.copy2(srcname, dstname)

class Store:
	def __init__(self, dir):
		self.dir = dir
	
	def lookup(self, digest):
		alg, value = digest.split('=', 1)
		assert alg == 'sha1'
		assert '/' not in value
		int(value, 16)		# Check valid format
		dir = os.path.join(self.dir, digest)
		if os.path.isdir(dir):
			return dir
		return None
	
	def add_archive_to_cache(self, required_digest, data, url, extract = None):
		import unpack
		assert required_digest.startswith('sha1=')
		info("Caching new implementation (digest %s)", required_digest)

		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		if not os.path.isdir(self.dir):
			os.makedirs(self.dir)
		tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
		try:
			unpack.unpack_archive(url, data, tmp, extract)
		except:
			shutil.rmtree(tmp)
			raise

		try:
			self.check_manifest_and_rename(required_digest, tmp, extract)
		except Exception, ex:
			warn("Leaving extracted directory as %s", tmp)
			raise
	
	def add_dir_to_cache(self, required_digest, path):
		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		if not os.path.isdir(self.dir):
			os.makedirs(self.dir)
		tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
		copytree2(path, tmp)
		try:
			self.check_manifest_and_rename(required_digest, tmp)
		except:
			warn("Error importing directory.")
			warn("Deleting %s", tmp)
			shutil.rmtree(tmp)
			raise

	def check_manifest_and_rename(self, required_digest, tmp, extract = None):
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception('Directory %s not found in archive' % extract)
		else:
			extracted = tmp

		sha1 = 'sha1=' + manifest.add_manifest_file(extracted, sha.new()).hexdigest()
		if sha1 != required_digest:
			raise BadDigest('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %s\n'
					'Actual digest: %s\n' %
					(required_digest, sha1))

		final_name = os.path.join(self.dir, required_digest)
		if os.path.isdir(final_name):
			raise Exception("Item %s already stored." % final_name)
		if extract:
			os.rename(os.path.join(tmp, extract), final_name)
			os.rmdir(tmp)
		else:
			os.rename(tmp, final_name)

class Stores(object):
	__slots__ = ['stores']

	def __init__(self):
		user_store = os.path.join(basedir.xdg_cache_home, '0install.net', 'implementations')
		self.stores = [Store(user_store)]

		impl_dirs = basedir.load_first_config('0install.net', 'injector',
							  'implementation-dirs')
		debug("Location of 'implementation-dirs' config file being used: '%s'", impl_dirs)
		if impl_dirs:
			dirs = file(impl_dirs)
		else:
			dirs = ['/var/cache/0install.net/implementations']
		for directory in dirs:
			directory = directory.strip()
			if directory and not directory.startswith('#'):
				if os.path.isdir(directory):
					self.stores.append(Store(directory))
					debug("Added system store '%s'", directory)
				else:
					info("Ignoring non-directory store '%s'", directory)

	def lookup(self, digest):
		"""Search for digest in all stores."""
		assert digest
		if '/' in digest or '=' not in digest:
			raise BadDigest('Syntax error in digest (use ALG=VALUE)')
		for store in self.stores:
			path = store.lookup(digest)
			if path:
				return path
		raise NotStored("Item with digest '%s' not found in stores. Searched:\n- %s" %
			(digest, '\n- '.join([s.dir for s in self.stores])))

	def add_dir_to_cache(self, required_digest, dir):
		self.stores[0].add_dir_to_cache(required_digest, dir)

	def add_archive_to_cache(self, required_digest, data, url, extract = None):
		self.stores[0].add_archive_to_cache(required_digest, data, url, extract)
