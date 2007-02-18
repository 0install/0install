"""
Code for managing the implementation cache.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from logging import debug, info, warn

from zeroinstall.injector import basedir
from zeroinstall import SafeException

class BadDigest(SafeException):
	"""Thrown if a digest is invalid (either syntactically or cryptographically)."""
	detail = None

class NotStored(SafeException):
	"""Throws if a requested implementation isn't in the cache."""

class NonwritableStore(SafeException):
	"""Attempt to add to a non-writable store directory."""

def _copytree2(src, dst):
	import shutil
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
			mtime = int(os.lstat(srcname).st_mtime)
			_copytree2(srcname, dstname)
			os.utime(dstname, (mtime, mtime))
		else:
			shutil.copy2(srcname, dstname)

def _wrap_umask(fn):
	def wrapper(self, *args, **kwargs):
		if self.public:
			old_umask = os.umask(0022)	# World readable
		try:
			fn(self, *args, **kwargs)
		finally:
			if self.public:
				os.umask(old_umask)
	return wrapper

class Store:
	"""A directory for storing implementations."""

	def __init__(self, dir, public = False):
		"""Create a new Store.
		@param dir: directory to contain the implementations
		@type dir: str
		@param public: set the umask for a public cache
		@type public: bool"""
		self.dir = dir
		self.public = public
	
	def __str__(self):
		return "Store '%s'" % self.dir
	
	def lookup(self, digest):
		alg, value = digest.split('=', 1)
		assert '/' not in value
		int(value, 16)		# Check valid format
		dir = os.path.join(self.dir, digest)
		if os.path.isdir(dir):
			return dir
		return None
	
	def get_tmp_dir_for(self, required_digest):
		"""Create a temporary directory in the directory where we would store an implementation
		with the given digest. This is used to setup a new implementation before being renamed if
		it turns out OK.
		@raise NonwritableStore: if we can't create it"""
		try:
			if not os.path.isdir(self.dir):
				os.makedirs(self.dir)
			from tempfile import mkdtemp
			tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
			old_mode = os.stat(tmp).st_mode
			os.chmod(tmp, old_mode | 0555)	# r-x for all; needed by 0store-helper
			return tmp
		except OSError, ex:
			raise NonwritableStore(str(ex))
	
	def add_archive_to_cache(self, required_digest, data, url, extract = None, type = None, start_offset = 0, try_helper = False):
		import unpack
		info("Caching new implementation (digest %s)", required_digest)

		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		tmp = self.get_tmp_dir_for(required_digest)
		try:
			unpack.unpack_archive(url, data, tmp, extract, type = type, start_offset = start_offset)
		except:
			import shutil
			shutil.rmtree(tmp)
			raise

		try:
			self.check_manifest_and_rename(required_digest, tmp, extract, try_helper = try_helper)
		except Exception, ex:
			warn("Leaving extracted directory as %s", tmp)
			raise
	add_archive_to_cache = _wrap_umask(add_archive_to_cache)
	
	def add_dir_to_cache(self, required_digest, path, try_helper = False):
		"""Copy the contents of path to the cache.
		@param required_digest: the expected digest
		@type required_digest: str
		@param path: the root of the tree to copy
		@type path: str
		@param try_helper: attempt to use privileged helper before user cache (since 0.26)
		@type try_helper: bool
		@raise BadDigest: if the contents don't match the given digest."""
		if self.lookup(required_digest):
			info("Not adding %s as it already exists!", required_digest)
			return

		if try_helper and self._add_with_helper(required_digest, path):
			return

		tmp = self.get_tmp_dir_for(required_digest)
		try:
			_copytree2(path, tmp)
			self.check_manifest_and_rename(required_digest, tmp)
		except:
			warn("Error importing directory.")
			warn("Deleting %s", tmp)
			import shutil
			shutil.rmtree(tmp)
			raise
	add_dir_to_cache = _wrap_umask(add_dir_to_cache)

	def _add_with_helper(self, required_digest, path):
		"""Use 0store-helper to copy 'path' to the system store.
		@param required_digest: the digest for path
		@type required_digest: str
		@param path: root of implementation directory structure
		@type path: str
		@return: True iff the directory was copied into the system cache successfully
		"""
		helper = unpack._find_in_path('0store-helper')
		if not helper:
			info("Command '0store-helper' not found in $PATH. Not importing to system store.")
			return False

		info("Trying to add to system cache using '%s'", helper)
		if os.spawnv(os.P_WAIT, helper, [helper, required_digest, path]):
			warn("0store-helper failed.")
			return False

		info("Added succcessfully.")
		return True

	def check_manifest_and_rename(self, required_digest, tmp, extract = None, try_helper = False):
		"""Check that tmp[/extract] has the required_digest.
		On success, rename the checked directory to the digest and,
		if self.public, make the whole tree read-only.
		@param try_helper: attempt to use privileged helper to import to system cache first (since 0.26)
		@type try_helper: bool
		@raise BadDigest: if the input directory doesn't match the given digest"""
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception('Directory %s not found in archive' % extract)
		else:
			extracted = tmp

		if try_helper:
			if self._add_with_helper(required_digest, extracted):
				import shutil
				shutil.rmtree(tmp)
				return
			info("Can't add to system store. Trying user store instead.")

		import manifest
		alg, required_value = manifest.splitID(required_digest)
		actual_digest = alg.getID(manifest.add_manifest_file(extracted, alg))
		if actual_digest != required_digest:
			raise BadDigest('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %s\n'
					'Actual digest: %s\n' %
					(required_digest, actual_digest))

		final_name = os.path.join(self.dir, required_digest)
		if os.path.isdir(final_name):
			raise Exception("Item %s already stored." % final_name)
		if extract:
			os.rename(os.path.join(tmp, extract), final_name)
			os.rmdir(tmp)
		else:
			os.rename(tmp, final_name)

		# Should we make private stores read-only too?
		if self.public:
			import stat
			os.chmod(final_name, 0555)
			for dirpath, dirnames, filenames in os.walk(final_name):
				for item in ['.'] + filenames:
					full = os.path.join(dirpath, item)
					finfo = os.lstat(full)
					if not stat.S_ISLNK(finfo.st_mode):
						os.chmod(full, finfo.st_mode & ~0222)


class Stores(object):
	"""A list of L{Store}s. All stores are searched when looking for an implementation.
	When storing, we use the first of the system caches (if writable), or the user's
	cache otherwise."""
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
				debug("Added system store '%s'", directory)
				self.stores.append(Store(directory, public = True))

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
		"""Add to the best writable cache.
		@see: L{Store.add_dir_to_cache}"""
		self._write_store(lambda store, **kwargs: store.add_dir_to_cache(required_digest, dir, **kwargs))

	def add_archive_to_cache(self, required_digest, data, url, extract = None, type = None, start_offset = 0):
		"""Add to the best writable cache.
		@see: L{Store.add_archive_to_cache}"""
		self._write_store(lambda store, **kwargs: store.add_archive_to_cache(required_digest,
						data, url, extract, type = type, start_offset = start_offset, **kwargs))
	
	def _write_store(self, fn):
		"""Call fn(first_system_store). If it's read-only, try again with the user store."""
		if len(self.stores) > 1:
			try:
				fn(self.stores[1])
				return
			except NonwritableStore:
				debug("%s not-writable. Trying helper instead.", self.stores[1])
				pass
		fn(self.stores[0], try_helper = True)
