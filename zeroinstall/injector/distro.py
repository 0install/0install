"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, re, glob, subprocess, sys
from logging import warn, info
from zeroinstall.injector import namespaces, model, arch
from zeroinstall.support import basedir

_dotted_ints = '[0-9]+(?:\.[0-9]+)*'

# This matches a version number that would be a valid Zero Install version without modification
_zeroinstall_regexp = '(?:%s)(?:-(?:pre|rc|post|)(?:%s))*' % (_dotted_ints, _dotted_ints)

# This matches the interesting bits of distribution version numbers
_version_regexp = '(%s)(-r%s)?' % (_zeroinstall_regexp, _dotted_ints)

# We try to do updates atomically without locking, but we don't worry too much about
# duplicate entries or being a little out of sync with the on-disk copy.
class Cache(object):
	def __init__(self, cache_leaf, source, format):
		"""Maintain a cache file (e.g. ~/.cache/0install.net/injector/$name).
		If the size or mtime of $source has changed, or the cache
		format version if different, reset the cache first."""
		self.cache_leaf = cache_leaf
		self.source = source
		self.format = format
		self.cache_dir = basedir.save_cache_path(namespaces.config_site,
							 namespaces.config_prog)
		self.cached_for = {}		# Attributes of source when cache was created
		try:
			self._load_cache()
		except Exception, ex:
			info(_("Failed to load cache (%s). Flushing..."), ex)
			self.flush()

	def flush(self):
		# Wipe the cache
		try:
			info = os.stat(self.source)
			mtime = int(info.st_mtime)
			size = info.st_size
		except Exception, ex:
			warn("Failed to stat %s: %s", self.source, ex)
			mtime = size = 0
		self.cache = {}
		import tempfile
		tmp, tmp_name = tempfile.mkstemp(dir = self.cache_dir)
		data = "mtime=%d\nsize=%d\nformat=%d\n\n" % (mtime, size, self.format)
		while data:
			wrote = os.write(tmp, data)
			data = data[wrote:]
		os.rename(tmp_name, os.path.join(self.cache_dir, self.cache_leaf))

		self._load_cache()

	# Populate self.cache from our saved cache file.
	# Throws an exception if the cache doesn't exist or has the wrong format.
	def _load_cache(self):
		self.cache = cache = {}
		stream = file(os.path.join(self.cache_dir, self.cache_leaf))
		try:
			meta = {}
			cached_format = False
			for line in stream:
				line = line.strip()
				if not line:
					break
				key, value = line.split('=', 1)
				if key in ('mtime', 'size', 'format'):
					self.cached_for[key] = int(value)

			self._check_valid()

			for line in stream:
				key, value = line.split('=', 1)
				cache[key] = value[:-1]
		finally:
			stream.close()

	# Check the source file hasn't changed since we created the cache
	def _check_valid(self):
		info = os.stat(self.source)
		if self.cached_for['mtime'] != int(info.st_mtime):
			raise Exception("Modification time of %s has changed" % self.source)
		if self.cached_for['size'] != info.st_size:
			raise Exception("Size of %s has changed" % self.source)
		if self.cached_for.get('format', None) != self.format:
			raise Exception("Format of cache has changed")

	def get(self, key):
		try:
			self._check_valid()
		except Exception, ex:
			info(_("Cache needs to be refreshed: %s"), ex)
			self.flush()
			return None
		else:
			return self.cache.get(key, None)

	def put(self, key, value):
		cache_path = os.path.join(self.cache_dir, self.cache_leaf)
		self.cache[key] = value
		try:
			stream = file(cache_path, 'a')
			try:
				stream.write('%s=%s\n' % (key, value))
			finally:
				stream.close()
		except Exception, ex:
			warn("Failed to write to cache %s: %s=%s: %s", cache_path, key, value, ex)

def try_cleanup_distro_version(version):
	"""Try to turn a distribution version string into one readable by Zero Install.
	We do this by stripping off anything we can't parse.
	@return: the part we understood, or None if we couldn't parse anything
	@rtype: str"""
	match = re.match(_version_regexp, version)
	if match:
		version, revision = match.groups()
		if revision is None:
			return version
		else:
			return '%s-%s' % (version, revision[2:])
	return None

class Distribution(object):
	"""Represents a distribution with which we can integrate.
	Sub-classes should specialise this to integrate with the package managers of
	particular distributions. This base class ignores the native package manager.
	@since: 0.28
	"""

	def get_package_info(self, package, factory):
		"""Get information about the given package.
		Add zero or more implementations using the factory (typically at most two
		will be added; the currently installed version and the latest available).
		@param package: package name (e.g. "gimp")
		@type package: str
		@param factory: function for creating new DistributionImplementation objects from IDs
		@type factory: str -> L{model.DistributionImplementation}
		"""
		return

	def get_score(self, distribution):
		"""Indicate how closely the host distribution matches this one.
		The <package-implementation> with the highest score is passed
		to L{Distribution.get_package_info}. If several elements get
		the same score, get_package_info is called for all of them.
		@param distribution: a distribution name
		@type distribution: str
		@return: an integer, or None if there is no match at all
		@rtype: int | None
		"""
		return 0

	def get_installed(self, package_id):
		"""Check whether 'package' is currently installed.
		@param package_id: the Implementation ID used by get_package_info
		@type package_id: str
		@return: True iff the package is currently installed"""
		return True

class CachedDistribution(Distribution):
	"""For distributions where querying the package database is slow (e.g. requires running
	an external command), we cache the results.
	@since: 0.39
	@deprecated: use Cache instead
	"""

	def __init__(self, db_status_file):
		"""@param db_status_file: update the cache when the timestamp of this file changes"""
		self._status_details = os.stat(db_status_file)

		self.versions = {}
		self.cache_dir = basedir.save_cache_path(namespaces.config_site,
							 namespaces.config_prog)

		try:
			self._load_cache()
		except Exception, ex:
			info(_("Failed to load distribution database cache (%s). Regenerating..."), ex)
			try:
				self.generate_cache()
				self._load_cache()
			except Exception, ex:
				warn(_("Failed to regenerate distribution database cache: %s"), ex)

	def _load_cache(self):
		"""Load {cache_leaf} cache file into self.versions if it is available and up-to-date.
		Throws an exception if the cache should be (re)created."""
		stream = file(os.path.join(self.cache_dir, self.cache_leaf))

		cache_version = None
		for line in stream:
			if line == '\n':
				break
			name, value = line.split(': ')
			if name == 'mtime' and int(value) != int(self._status_details.st_mtime):
				raise Exception(_("Modification time of package database file has changed"))
			if name == 'size' and int(value) != self._status_details.st_size:
				raise Exception(_("Size of package database file has changed"))
			if name == 'version':
				cache_version = int(value)
		else:
			raise Exception(_('Invalid cache format (bad header)'))

		if cache_version is None:
			raise Exception(_('Old cache format'))

		versions = self.versions
		for line in stream:
			package, version, zi_arch = line[:-1].split('\t')
			versionarch = (version, intern(zi_arch))
			if package not in versions:
				versions[package] = [versionarch]
			else:
				versions[package].append(versionarch)

	def _write_cache(self, cache):
		#cache.sort() 	# Might be useful later; currently we don't care
		import tempfile
		fd, tmpname = tempfile.mkstemp(prefix = 'zeroinstall-cache-tmp',
					       dir = self.cache_dir)
		try:
			stream = os.fdopen(fd, 'wb')
			stream.write('version: 2\n')
			stream.write('mtime: %d\n' % int(self._status_details.st_mtime))
			stream.write('size: %d\n' % self._status_details.st_size)
			stream.write('\n')
			for line in cache:
				stream.write(line + '\n')
			stream.close()

			os.rename(tmpname,
				  os.path.join(self.cache_dir,
					       self.cache_leaf))
		except:
			os.unlink(tmpname)
			raise

# Maps machine type names used in packages to their Zero Install versions
_canonical_machine = {
	'all' : '*',
	'any' : '*',
	'amd64': 'x86_64',
	'i386': 'i386',
}

host_machine = os.uname()[-1]
def canonical_machine(package_machine):
	machine = _canonical_machine.get(package_machine, None)
	if machine is None:
		# Safe default if we can't understand the arch
		return host_machine
	return machine

class DebianDistribution(Distribution):
	"""A dpkg-based distribution."""

	cache_leaf = 'dpkg-status.cache'

	def __init__(self, dpkg_status, pkgcache):
		self.dpkg_cache = Cache('dpkg-status.cache', dpkg_status, 2)
		self.apt_cache = Cache('apt-cache-cache', pkgcache, 3)

	def _query_installed_package(self, package):
		child = subprocess.Popen(["dpkg-query", "-W", "--showformat=${Version}\t${Architecture}\t${Status}\n", "--", package],
						stdout = subprocess.PIPE)
		stdout, stderr = child.communicate()
		child.wait()
		for line in stdout.split('\n'):
			if not line: continue
			version, debarch, status = line.split('\t', 2)
			if not status.endswith(' installed'): continue
			if ':' in version:
				# Debian's 'epoch' system
				version = version.split(':', 1)[1]
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				return '%s\t%s' % (clean_version, canonical_machine(debarch.strip()))
			else:
				warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})

		return '-'

	def get_package_info(self, package, factory):
		installed_cached_info = self._get_dpkg_info(package)

		if installed_cached_info != '-':
			installed_version, machine = installed_cached_info.split('\t')
			impl = factory('package:deb:%s:%s' % (package, installed_version))
			impl.version = model.parse_version(installed_version)
			if machine != '*':
				impl.machine = machine
		else:
			installed_version = None

		# Check to see whether we could get a newer version using apt-get

		cached = self.apt_cache.get(package)
		if cached is None:
			try:
				null = os.open('/dev/null', os.O_WRONLY)
				child = subprocess.Popen(['apt-cache', 'show', '--no-all-versions', '--', package], stdout = subprocess.PIPE, stderr = null)
				os.close(null)

				arch = version = size = None
				for line in child.stdout:
					line = line.strip()
					if line.startswith('Version: '):
						version = line[9:]
						if ':' in version:
							# Debian's 'epoch' system
							version = version.split(':', 1)[1]
						version = try_cleanup_distro_version(version)
					elif line.startswith('Architecture: '):
						arch = canonical_machine(line[14:].strip())
					elif line.startswith('Size: '):
						size = int(line[6:].strip())
				if version and arch:
					cached = '%s\t%s\t%d' % (version, arch, size)
				else:
					cached = '-'
				child.wait()
			except Exception, ex:
				warn("'apt-cache show %s' failed: %s", package, ex)
				cached = '-'
			# (multi-arch support? can there be multiple candidates?)
			self.apt_cache.put(package, cached)

		if cached != '-':
			candidate_version, candidate_arch, candidate_size = cached.split('\t')
			if candidate_version and candidate_version != installed_version:
				impl = factory('package:deb:%s:%s' % (package, candidate_version))
				impl.version = model.parse_version(candidate_version)
				if candidate_arch != '*':
					impl.machine = candidate_arch
				impl.download_sources.append(model.DistributionSource(package, candidate_size))

	def get_score(self, disto_name):
		return int(disto_name == 'Debian')

	def _get_dpkg_info(self, package):
		installed_cached_info = self.dpkg_cache.get(package)
		if installed_cached_info == None:
			installed_cached_info = self._query_installed_package(package)
			self.dpkg_cache.put(package, installed_cached_info)

		return installed_cached_info

	def get_installed(self, package_id):
		details = package_id.split(':', 3)
		assert details[0] == 'package'
		package = details[2]
		info = self._get_dpkg_info(package)
		if info is '-': return False
		installed_version, machine = info.split('\t')
		installed_id = 'package:deb:%s:%s' % (package, installed_version)
		return package_id == installed_id

class RPMDistribution(CachedDistribution):
	"""An RPM-based distribution."""

	cache_leaf = 'rpm-status.cache'

	def generate_cache(self):
		cache = []

		for line in os.popen("rpm -qa --qf='%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n'"):
			package, version, rpmarch = line.split('\t', 2)
			if package == 'gpg-pubkey':
				continue
			if rpmarch == 'amd64\n':
				zi_arch = 'x86_64'
			elif rpmarch == 'noarch\n' or rpmarch == "(none)\n":
				zi_arch = '*'
			else:
				zi_arch = rpmarch.strip()
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				cache.append('%s\t%s\t%s' % (package, clean_version, zi_arch))
			else:
				warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})

		self._write_cache(cache)

	def get_package_info(self, package, factory):
		try:
			versions = self.versions[package]
		except KeyError:
			return

		for version, machine in versions:
			impl = factory('package:rpm:%s:%s:%s' % (package, version, machine))
			impl.version = model.parse_version(version)
			if machine != '*':
				impl.machine = machine

	def get_score(self, disto_name):
		return int(disto_name == 'RPM')

class GentooDistribution(Distribution):

	def __init__(self, pkgdir):
		self._pkgdir = pkgdir

	def get_package_info(self, package, factory):
		_version_start_reqexp = '-[0-9]'

		if package.count('/') != 1: return

		category, leafname = package.split('/')
		category_dir = os.path.join(self._pkgdir, category)
		match_prefix = leafname + '-'

		if not os.path.isdir(category_dir): return

		for filename in os.listdir(category_dir):
			if filename.startswith(match_prefix) and filename[len(match_prefix)].isdigit():
				name = file(os.path.join(category_dir, filename, 'PF')).readline().strip()

				match = re.search(_version_start_reqexp, name)
				if match is None:
					warn(_('Cannot parse version from Gentoo package named "%(name)s"'), {'name': name})
					continue
				else:
					version = try_cleanup_distro_version(name[match.start() + 1:])

				if category == 'app-emulation' and name.startswith('emul-'):
					__, __, machine, __ = name.split('-', 3)
				else:
					machine, __ = file(os.path.join(category_dir, filename, 'CHOST')).readline().split('-', 1)
				machine = arch.canonicalize_machine(machine)

				impl = factory('package:gentoo:%s:%s:%s' % \
						(package, version, machine))
				impl.version = model.parse_version(version)
				impl.machine = machine

	def get_score(self, disto_name):
		return int(disto_name == 'Gentoo')

class PortsDistribution(Distribution):

	def __init__(self, pkgdir):
		self._pkgdir = pkgdir

	def get_package_info(self, package, factory):
		_version_start_reqexp = '-[0-9]'

		for pkgname in os.listdir(self._pkgdir):
			pkgdir = os.path.join(self._pkgdir, pkgname)
			if not os.path.isdir(pkgdir): continue

			#contents = file(os.path.join(pkgdir, '+CONTENTS')).readline().strip()

			match = re.search(_version_start_reqexp, pkgname)
			if match is None:
				warn(_('Cannot parse version from Ports package named "%(pkgname)s"'), {'name': pkgname})
				continue
			else:
				name = pkgname[0:match.start()]
				version = try_cleanup_distro_version(pkgname[match.start() + 1:])

			machine = arch.canonicalize_machine(host_machine)

			impl = factory('package:ports:%s:%s:%s' % \
						(package, version, machine))
			impl.version = model.parse_version(version)
			impl.machine = machine

	def get_score(self, disto_name):
		return int(disto_name == 'Ports')

_host_distribution = None
def get_host_distribution():
	"""Get a Distribution suitable for the host operating system.
	Calling this twice will return the same object.
	@rtype: L{Distribution}"""
	global _host_distribution
	if not _host_distribution:
		dpkg_db_status = '/var/lib/dpkg/status'
		pkgcache = '/var/cache/apt/pkgcache.bin'
		_rpm_db = '/var/lib/rpm/Packages'
		_pkg_db = '/var/db/pkg'

		if os.path.isdir(_pkg_db):
			if sys.platform.startswith("linux"):
				_host_distribution = GentooDistribution(_pkg_db)
			elif sys.platform.startswith("freebsd"):
				_host_distribution = PortsDistribution(_pkg_db)
		elif os.access(dpkg_db_status, os.R_OK):
			_host_distribution = DebianDistribution(dpkg_db_status, pkgcache)
		elif os.path.isfile(_rpm_db):
			_host_distribution = RPMDistribution(_rpm_db)
		else:
			_host_distribution = Distribution()

	return _host_distribution
