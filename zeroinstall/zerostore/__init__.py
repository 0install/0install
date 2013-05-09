"""
Code for managing the implementation cache.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger
import os

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
	"""@type src: str
	@type dst: str"""
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

def _validate_pair(value):
	"""@type value: str"""
	if '/' in value or \
	   '\\' in value or \
	   value.startswith('.'):
		raise BadDigest("Invalid digest '{value}'".format(value = value))

def parse_algorithm_digest_pair(src):
	"""Break apart an algorithm/digest into in a tuple.
	Old algorithms use '=' as the separator, while newer ones use '_'.
	@param src: the combined string
	@type src: str
	@return: the parsed values
	@rtype: (str, str)
	@raise BadDigest: if it can't be parsed
	@since: 1.10"""
	_validate_pair(src)
	if src.startswith('sha1=') or src.startswith('sha1new=') or src.startswith('sha256='):
		return src.split('=', 1)
	result = src.split('_', 1)
	if len(result) != 2:
		if '=' in src:
			raise BadDigest("Use '_' not '=' for new algorithms, in {src}".format(src = src))
		raise BadDigest("Can't parse digest {src}".format(src = src))
	return result

def format_algorithm_digest_pair(alg, digest):
	"""The opposite of L{parse_algorithm_digest_pair}.
	The result is suitable for use as a directory name (does not contain '/' characters).
	@type alg: str
	@type digest: str
	@rtype: str
	@raise BadDigest: if the result is invalid
	@since: 1.10"""
	if alg in ('sha1', 'sha1new', 'sha256'):
		result = alg + '=' + digest
	else:
		result = alg + '_' + digest
	_validate_pair(result)
	return result

class Store(object):
	"""A directory for storing implementations."""

	def __init__(self, dir, public = False):
		"""Create a new Store.
		@param dir: directory to contain the implementations
		@type dir: str
		@param public: deprecated
		@type public: bool"""
		self.dir = dir
		self.dry_run_names = set()
	
	def __str__(self):
		return _("Store '%s'") % self.dir
	
	def lookup(self, digest):
		"""@type digest: str
		@rtype: str"""
		alg, value = parse_algorithm_digest_pair(digest)
		dir = os.path.join(self.dir, digest)
		if os.path.isdir(dir) or digest in self.dry_run_names:
			return dir
		return None
	
	def get_tmp_dir_for(self, required_digest):
		"""Create a temporary directory in the directory where we would store an implementation
		with the given digest. This is used to setup a new implementation before being renamed if
		it turns out OK.
		@type required_digest: str
		@rtype: str
		@raise NonwritableStore: if we can't create it"""
		try:
			if not os.path.isdir(self.dir):
				os.makedirs(self.dir)
			from tempfile import mkdtemp
			tmp = mkdtemp(dir = self.dir, prefix = 'tmp-')
			os.chmod(tmp, 0o755)	# r-x for all; needed by 0store-helper
			return tmp
		except OSError as ex:
			raise NonwritableStore(str(ex))
	
	def add_archive_to_cache(self, required_digest, data, url, extract = None, type = None, start_offset = 0, try_helper = False, dry_run = False):
		"""@type required_digest: str
		@type data: file
		@type url: str
		@type extract: str | None
		@type type: str | None
		@type start_offset: int
		@type try_helper: bool
		@type dry_run: bool"""
		from . import unpack

		if self.lookup(required_digest):
			logger.info(_("Not adding %s as it already exists!"), required_digest)
			return

		tmp = self.get_tmp_dir_for(required_digest)
		try:
			unpack.unpack_archive(url, data, tmp, extract, type = type, start_offset = start_offset)
		except:
			import shutil
			shutil.rmtree(tmp)
			raise

		try:
			self.check_manifest_and_rename(required_digest, tmp, extract, try_helper = try_helper, dry_run = dry_run)
		except Exception:
			#warn(_("Leaving extracted directory as %s"), tmp)
			support.ro_rmtree(tmp)
			raise
	
	def add_dir_to_cache(self, required_digest, path, try_helper = False, dry_run = False):
		"""Copy the contents of path to the cache.
		@param required_digest: the expected digest
		@type required_digest: str
		@param path: the root of the tree to copy
		@type path: str
		@param try_helper: attempt to use privileged helper before user cache (since 0.26)
		@type try_helper: bool
		@type dry_run: bool
		@raise BadDigest: if the contents don't match the given digest."""
		if self.lookup(required_digest):
			logger.info(_("Not adding %s as it already exists!"), required_digest)
			return

		tmp = self.get_tmp_dir_for(required_digest)
		try:
			_copytree2(path, tmp)
			self.check_manifest_and_rename(required_digest, tmp, try_helper = try_helper, dry_run = dry_run)
		except:
			logger.warning(_("Error importing directory."))
			logger.warning(_("Deleting %s"), tmp)
			support.ro_rmtree(tmp)
			raise

	def _add_with_helper(self, required_digest, path, dry_run):
		"""Use 0store-secure-add to copy 'path' to the system store.
		@param required_digest: the digest for path
		@type required_digest: str
		@param path: root of implementation directory structure
		@type path: str
		@return: True iff the directory was copied into the system cache successfully"""
		if required_digest.startswith('sha1='):
			return False		# Old digest alg not supported
		if os.environ.get('ZEROINSTALL_PORTABLE_BASE'):
			return False		# Can't use helper with portable mode
		helper = support.find_in_path('0store-secure-add-helper')
		if not helper:
			logger.info(_("'0store-secure-add-helper' command not found. Not adding to system cache."))
			return False
		if dry_run:
			print(_("[dry-run] would use {helper} to store {required_digest} in system store").format(
				helper = helper,
				required_digest = required_digest))
			self.dry_run_names.add(required_digest)
			return True
		import subprocess
		env = os.environ.copy()
		env['ENV_NOT_CLEARED'] = 'Unclean'	# (warn about insecure configurations)
		env['HOME'] = 'Unclean'			# (warn about insecure configurations)
		dev_null = os.open(os.devnull, os.O_RDONLY)
		try:
			logger.info(_("Trying to add to system cache using %s"), helper)
			child = subprocess.Popen([helper, required_digest],
						 stdin = dev_null,
						 cwd = path,
						 env = env)
			exit_code = child.wait()
		finally:
			os.close(dev_null)

		if exit_code:
			logger.warning(_("0store-secure-add-helper failed."))
			return False

		logger.info(_("Added succcessfully."))
		return True

	def check_manifest_and_rename(self, required_digest, tmp, extract = None, try_helper = False, dry_run = False):
		"""Check that tmp[/extract] has the required_digest.
		On success, rename the checked directory to the digest, and
		make the whole tree read-only.
		@type required_digest: str
		@type tmp: str
		@type extract: str | None
		@param try_helper: attempt to use privileged helper to import to system cache first (since 0.26)
		@type try_helper: bool
		@param dry_run: just print what we would do to stdout (and delete tmp)
		@type dry_run: bool
		@raise BadDigest: if the input directory doesn't match the given digest"""
		if extract:
			extracted = os.path.join(tmp, extract)
			if not os.path.isdir(extracted):
				raise Exception(_('Directory %s not found in archive') % extract)
		else:
			extracted = tmp

		from . import manifest

		manifest.fixup_permissions(extracted)

		alg, required_value = manifest.splitID(required_digest)
		actual_digest = alg.getID(manifest.add_manifest_file(extracted, alg))
		if actual_digest != required_digest:
			raise BadDigest(_('Incorrect manifest -- archive is corrupted.\n'
					'Required digest: %(required_digest)s\n'
					'Actual digest: %(actual_digest)s\n') %
					{'required_digest': required_digest, 'actual_digest': actual_digest})

		if try_helper:
			if self._add_with_helper(required_digest, extracted, dry_run = dry_run):
				support.ro_rmtree(tmp)
				return
			logger.info(_("Can't add to system store. Trying user store instead."))

		logger.info(_("Caching new implementation (digest %s) in %s"), required_digest, self.dir)

		final_name = os.path.join(self.dir, required_digest)
		if os.path.isdir(final_name):
			logger.warning(_("Item %s already stored.") % final_name) # not really an error
			return

		if dry_run:
			print(_("[dry-run] would store implementation as {path}").format(path = final_name))
			self.dry_run_names.add(required_digest)
			support.ro_rmtree(tmp)
			return
		else:
			# If we just want a subdirectory then the rename will change
			# extracted/.. and so we'll need write permission on 'extracted'

			os.chmod(extracted, 0o755)
			os.rename(extracted, final_name)
			os.chmod(final_name, 0o555)

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
		# Always add the user cache to have a reliable fallback location for storage
		user_store = os.path.join(basedir.xdg_cache_home, '0install.net', 'implementations')
		self.stores = [Store(user_store)]

		# Add custom cache locations
		dirs = []
		for impl_dirs in basedir.load_config_paths('0install.net', 'injector', 'implementation-dirs'):
			with open(impl_dirs, 'rt') as stream:
				dirs.extend(stream.readlines())
		for directory in dirs:
			directory = directory.strip()
			if directory and not directory.startswith('#'):
				logger.debug(_("Added system store '%s'"), directory)
				self.stores.append(Store(directory))

		# Add the system cache when not in portable mode
		if not os.environ.get('ZEROINSTALL_PORTABLE_BASE'):
			if os.name == "nt":
				from win32com.shell import shell, shellcon
				commonAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_COMMON_APPDATA, 0, 0)
				systemCachePath = os.path.join(commonAppData, "0install.net", "implementations")
				# Only use shared cache location on Windows if it was explicitly created
				if os.path.isdir(systemCachePath):
					self.stores.append(Store(systemCachePath))
			else:
				self.stores.append(Store('/var/cache/0install.net/implementations'))

	def lookup(self, digest):
		"""@type digest: str
		@rtype: str
		@deprecated: use lookup_any instead"""
		return self.lookup_any([digest])

	def lookup_any(self, digests):
		"""Search for digest in all stores.
		@type digests: [str]
		@rtype: str
		@raises NotStored: if not found"""
		path = self.lookup_maybe(digests)
		if path:
			return path
		raise NotStored(_("Item with digests '%(digests)s' not found in stores. Searched:\n- %(stores)s") %
			{'digests': digests, 'stores': '\n- '.join([s.dir for s in self.stores])})

	def lookup_maybe(self, digests):
		"""Like lookup_any, but return None if it isn't found.
		@type digests: [str]
		@rtype: str | None
		@since: 0.53"""
		assert digests
		for digest in digests:
			assert digest
			_validate_pair(digest)
			for store in self.stores:
				path = store.lookup(digest)
				if path:
					return path
		return None

	def add_dir_to_cache(self, required_digest, dir, dry_run = False):
		"""Add to the best writable cache.
		@type required_digest: str
		@type dir: str
		@type dry_run: bool
		@see: L{Store.add_dir_to_cache}"""
		self._write_store(lambda store, **kwargs: store.add_dir_to_cache(required_digest, dir, dry_run = dry_run, **kwargs))

	def add_archive_to_cache(self, required_digest, data, url, extract = None, type = None, start_offset = 0, dry_run = False):
		"""Add to the best writable cache.
		@type required_digest: str
		@type data: file
		@type url: str
		@type extract: str | None
		@type type: str | None
		@type start_offset: int
		@type dry_run: bool
		@see: L{Store.add_archive_to_cache}"""
		self._write_store(lambda store, **kwargs: store.add_archive_to_cache(required_digest,
						data, url, extract, type = type, start_offset = start_offset, dry_run = dry_run, **kwargs))
	
	def check_manifest_and_rename(self, required_digest, tmp, dry_run = False):
		"""Check that tmp has the required_digest and move it into the stores. On success, tmp no longer exists.
		@since: 2.3"""
		if len(self.stores) > 1:
			store = self.get_first_system_store()
			try:
				store.add_dir_to_cache(required_digest, tmp, dry_run = dry_run)
				support.ro_rmtree(tmp)
				return
			except NonwritableStore:
				logger.debug(_("%s not-writable. Trying helper instead."), store)
				pass
		self.stores[0].check_manifest_and_rename(required_digest, tmp, dry_run = dry_run, try_helper = True)

	def _write_store(self, fn):
		"""Call fn(first_system_store). If it's read-only, try again with the user store."""
		if len(self.stores) > 1:
			try:
				fn(self.get_first_system_store())
				return
			except NonwritableStore:
				logger.debug(_("%s not-writable. Trying helper instead."), self.get_first_system_store())
				pass
		fn(self.stores[0], try_helper = True)

	def get_first_system_store(self):
		"""The first system store is the one we try writing to first.
		@rtype: L{Store}
		@since: 0.30"""
		try:
			return self.stores[1]
		except IndexError:
			raise SafeException(_("No system stores have been configured"))
