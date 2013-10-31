"""
Code for managing the implementation cache.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger
import os

from zeroinstall.support import basedir
from zeroinstall import SafeException

class BadDigest(SafeException):
	"""Thrown if a digest is invalid (either syntactically or cryptographically)."""
	detail = None

class NotStored(SafeException):
	"""Throws if a requested implementation isn't in the cache."""

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
