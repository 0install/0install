"""
Code for managing the implementation cache.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from logging import debug, info, warn

from zeroinstall.support import basedir
from zeroinstall import SafeException, support

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

class Store:
	"""A directory for storing implementations."""

	def __init__(self, dir, public = False):
		"""Create a new Store.
		@param dir: directory to contain the implementations
		@type dir: str
		@param public: deprecated
		@type public: bool"""
		self.dir = dir
	
	def __str__(self):
		return _("Store '%s'") % self.dir
	
	def lookup(self, digest):
		try:
			alg, value = digest.split('=', 1)
		except ValueError:
			raise BadDigest(_("Digest must be in the form ALG=VALUE, not '%s'") % digest)
		try:
			assert '/' not in value
			int(value, 16)		# Check valid format
		except ValueError, ex:
			raise BadDigest(_("Bad value for digest: %s") % str(ex))
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
			os.chmod(tmp, 0755)	# r-x for all; needed by 0store-helper
			return tmp
		except OSError, ex:
			raise NonwritableStore(str(ex))
	
	def add_archive_to_cache(self, required_digest, data, url, extract = None, type = None, start_offset = 0, try_helper = False):
		import unpack
		info(_("Caching new implementation (digest %s) in %s"), required_digest, self.dir)

		if self.lookup(required_digest):
			info(_("Not adding %s as it already exists!"), required_digest)
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
		except Exception:
			warn(_("Leaving extracted directory as %s"), tmp)
			raise
	
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
			info(_("Not adding %s as it already exists!"), required_digest)
			return

		tmp = self.get_tmp_dir_for(required_digest)
		try:
			_copytree2(path, tmp)
			self.check_manifest_and_rename(required_digest, tmp, try_helper = try_helper)
		except:
			warn(_("Error importing directory."))
			warn(_("Deleting %s"), tmp)
			support.ro_rmtree(tmp)
			raise

	def _add_with_helper(self, required_digest, path):
		"""Use 0store-secure-add to copy 'path' to the system store.
		@param required_digest: the digest for path
		@type required_digest: str
		@param path: root of implementation directory structure
		@type path: str
		@return: True iff the directory was copied into the system cache successfully
		"""
		if required_digest.startswith('sha1='):
			return False		# Old digest alg not supported
		helper = support.find_in_path('0store-secure-add-helper')
		if not helper:
			info(_("'0store-secure-add-helper' command not found. Not adding to system cache."))
			return False
		import subprocess
		env = os.environ.copy()
		env['ENV_NOT_CLEARED'] = 'Unclean'	# (warn about insecure configurations)
		env['HOME'] = 'Unclean'			# (warn about insecure configurations)
		dev_null = os.open('/dev/null', os.O_RDONLY)
		try:
			info(_("Trying to add to system cache using %s"), helper)
			child = subprocess.Popen([helper, required_digest],
						 stdin = dev_null,
						 cwd = path,
						 env = env)
			exit_code = child.wait()
		finally:
			os.close(dev_null)

		if exit_code:
			warn(_("0store-secure-add-helper failed."))
			return False

		info(_("Added succcessfully."))
		return True

	def check_manifest_and_rename(self, required_digest, tmp, extract = None, try_helper = False):
		"""Check that tmp[/extract] has the required_digest.
		On success, rename the checked directory to the digest, and
		make the whole tree read-only.
		@param try_helper: attempt to use privileged helper to import to system cache first (since 0.26)
		@type try_helper: bool
		@raise BadDigest: if the input directory doesn't match the given digest"""
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception(_('Directory %s not found in archive') % extract)
		else:
			extracted = tmp

		import manifest

		manifest.fixup_permissions(extracted)

		alg, required_value = manifest.splitID(required_digest)
		actual_digest = alg.getID(manifest.add_manifest_file(extracted, alg))
		if actual_digest != required_digest:
			raise BadDigest(_('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %(required_digest)s\n'
					'Actual digest: %(actual_digest)s\n') %
					{'required_digest': required_digest, 'actual_digest': actual_digest})

		if try_helper:
			if self._add_with_helper(required_digest, extracted):
				support.ro_rmtree(tmp)
				return
			info(_("Can't add to system store. Trying user store instead."))

		final_name = os.path.join(self.dir, required_digest)
		if os.path.isdir(final_name):
			raise Exception(_("Item %s already stored.") % final_name) # XXX: not really an error

		# If we just want a subdirectory then the rename will change
		# extracted/.. and so we'll need write permission on 'extracted'

		os.chmod(extracted, 0755)
		os.rename(extracted, final_name)
		os.chmod(final_name, 0555)

		if extract:
			os.rmdir(tmp)

	def __repr__(self):
		return "<store: %s>" % self.dir

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
		debug(_("Location of 'implementation-dirs' config file being used: '%s'"), impl_dirs)
		if impl_dirs:
			dirs = file(impl_dirs)
		else:
			if os.name == "nt":
				from win32com.shell import shell, shellcon
				localAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_LOCAL_APPDATA, 0, 0)
				commonAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_COMMON_APPDATA, 0, 0)

				userCache = os.path.join(localAppData, "0install.net", "implementations")
				sharedCache = os.path.join(commonAppData, "0install.net", "implementations")
				dirs = [userCache, sharedCache]

			else:
				dirs = ['/var/cache/0install.net/implementations']

		for directory in dirs:
			directory = directory.strip()
			if directory and not directory.startswith('#'):
				debug(_("Added system store '%s'"), directory)
				self.stores.append(Store(directory))

	def lookup(self, digest):
		return self.lookup_any([digest])

	def lookup_any(self, digests):
		"""Search for digest in all stores."""
		assert digests
		for digest in digests:
			assert digest
			if '/' in digest or '=' not in digest:
				raise BadDigest(_('Syntax error in digest (use ALG=VALUE, not %s)') % digest)
			for store in self.stores:
				path = store.lookup(digest)
				if path:
					return path
		raise NotStored(_("Item with digests '%(digests)s' not found in stores. Searched:\n- %(stores)s") %
			{'digests': digests, 'stores': '\n- '.join([s.dir for s in self.stores])})

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
				fn(self.get_first_system_store())
				return
			except NonwritableStore:
				debug(_("%s not-writable. Trying helper instead."), self.get_first_system_store())
				pass
		fn(self.stores[0], try_helper = True)

	def get_first_system_store(self):
		"""The first system store is the one we try writing to first.
		@since: 0.30"""
		try:
			return self.stores[1]
		except IndexError:
			raise SafeException(_("No system stores have been configured"))
