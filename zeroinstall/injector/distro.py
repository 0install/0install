"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, platform, re, subprocess, sys
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
	if ':' in version:
		version = version.split(':')[1]	# Skip 'epoch'
	version = version.replace('_', '-')
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
	_packagekit = None

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

	def get_feed(self, master_feed):
		"""Generate a feed containing information about distribution packages.
		This should immediately return a feed containing an implementation for the
		package if it's already installed. Information about versions that could be
		installed using the distribution's package manager can be added asynchronously
		later (see L{fetch_candidates}).
		@param master_feed: feed containing the <package-implementation> elements
		@type master_feed: L{model.ZeroInstallFeed}
		@rtype: L{model.ZeroInstallFeed}"""

		feed = model.ZeroInstallFeed(None)
		feed.url = 'distribution:' + master_feed.url

		for item, item_attrs in master_feed.get_package_impls(self):
			package = item_attrs.get('package', None)
			if package is None:
				raise model.InvalidInterface(_("Missing 'package' attribute on %s") % item)

			def factory(id, only_if_missing = False, installed = True):
				assert id.startswith('package:')
				if id in feed.implementations:
					if only_if_missing:
						return None
					warn(_("Duplicate ID '%s' for DistributionImplementation"), id)
				impl = model.DistributionImplementation(feed, id, self)
				feed.implementations[id] = impl

				impl.installed = installed
				impl.metadata = item_attrs

				item_main = item_attrs.get('main', None)
				if item_main and not item_main.startswith('/'):
					raise model.InvalidInterface(_("'main' attribute must be absolute, but '%s' doesn't start with '/'!") %
								item_main)
				impl.main = item_main
				impl.upstream_stability = model.packaged

				return impl

			self.get_package_info(package, factory)
		return feed

	def fetch_candidates(self, master_feed):
		"""Collect information about versions we could install using
		the distribution's package manager. On success, the distribution
		feed in iface_cache is updated.
		@return: a L{tasks.Blocker} if the task is in progress, or None if not"""
		if self.packagekit.available:
			package_names = [item.getAttribute("package") for item, item_attrs in master_feed.get_package_impls(self)]
			return self.packagekit.fetch_candidates(package_names)

	@property
	def packagekit(self):
		"""For use by subclasses.
		@rtype: L{packagekit.PackageKit}"""
		if not self._packagekit:
			from zeroinstall.injector import packagekit
			self._packagekit = packagekit.PackageKit()
		return self._packagekit

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
	'noarch' : '*',
	'(none)' : '*',
	'amd64': 'x86_64',
	'i386': 'i386',
	'i486': 'i486',
	'i586': 'i586',
	'i686': 'i686',
	'ppc64': 'ppc64',
	'ppc': 'ppc',
}

host_machine = arch.canonicalize_machine(platform.uname()[4])
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
		self.apt_cache = {}

	def _query_installed_package(self, package):
		null = os.open('/dev/null', os.O_WRONLY)
		child = subprocess.Popen(["dpkg-query", "-W", "--showformat=${Version}\t${Architecture}\t${Status}\n", "--", package],
						stdout = subprocess.PIPE, stderr = null)
		os.close(null)
		stdout, stderr = child.communicate()
		child.wait()
		for line in stdout.split('\n'):
			if not line: continue
			version, debarch, status = line.split('\t', 2)
			if not status.endswith(' installed'): continue
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				return '%s\t%s' % (clean_version, canonical_machine(debarch.strip()))
			else:
				warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})

		return '-'

	def get_package_info(self, package, factory):
		# Add any already-installed package...
		installed_cached_info = self._get_dpkg_info(package)

		if installed_cached_info != '-':
			installed_version, machine = installed_cached_info.split('\t')
			impl = factory('package:deb:%s:%s:%s' % (package, installed_version, machine))
			impl.version = model.parse_version(installed_version)
			if machine != '*':
				impl.machine = machine
		else:
			installed_version = None

		# Add any uninstalled candidates (note: only one of these two methods will add anything)

		# From PackageKit...
		self.packagekit.get_candidates(package, factory, 'package:deb')

		# From apt-cache...
		cached = self.apt_cache.get(package, None)
		if cached:
			candidate_version = cached['version']
			candidate_arch = cached['arch']
			if candidate_version and candidate_version != installed_version:
				impl = factory('package:deb:%s:%s:%s' % (package, candidate_version, candidate_arch), installed = False)
				impl.version = model.parse_version(candidate_version)
				if candidate_arch != '*':
					impl.machine = candidate_arch
				def install(handler):
					raise model.SafeException(_("This program depends on '%s', which is a package that is available through your distribution. "
							"Please install it manually using your distribution's tools and try again.") % package)
				impl.download_sources.append(model.DistributionSource(package, cached['size'], install, needs_confirmation = False))

	def get_score(self, disto_name):
		return int(disto_name == 'Debian')

	def _get_dpkg_info(self, package):
		installed_cached_info = self.dpkg_cache.get(package)
		if installed_cached_info == None:
			installed_cached_info = self._query_installed_package(package)
			self.dpkg_cache.put(package, installed_cached_info)

		return installed_cached_info

	def fetch_candidates(self, master_feed):
		package_names = [item.getAttribute("package") for item, item_attrs in master_feed.get_package_impls(self)]

		if self.packagekit.available:
			return self.packagekit.fetch_candidates(package_names)

		# No PackageKit. Use apt-cache directly.
		for package in package_names:
			# Check to see whether we could get a newer version using apt-get
			try:
				null = os.open('/dev/null', os.O_WRONLY)
				child = subprocess.Popen(['apt-cache', 'show', '--no-all-versions', '--', package], stdout = subprocess.PIPE, stderr = null)
				os.close(null)

				arch = version = size = None
				for line in child.stdout:
					line = line.strip()
					if line.startswith('Version: '):
						version = line[9:]
						version = try_cleanup_distro_version(version)
					elif line.startswith('Architecture: '):
						arch = canonical_machine(line[14:].strip())
					elif line.startswith('Size: '):
						size = int(line[6:].strip())
				if version and arch:
					cached = {'version': version, 'arch': arch, 'size': size}
				else:
					cached = None
				child.wait()
			except Exception, ex:
				warn("'apt-cache show %s' failed: %s", package, ex)
				cached = None
			# (multi-arch support? can there be multiple candidates?)
			self.apt_cache[package] = cached

class RPMDistribution(CachedDistribution):
	"""An RPM-based distribution."""

	cache_leaf = 'rpm-status.cache'

	def generate_cache(self):
		cache = []

		for line in os.popen("rpm -qa --qf='%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n'"):
			package, version, rpmarch = line.split('\t', 2)
			if package == 'gpg-pubkey':
				continue
			zi_arch = canonical_machine(rpmarch.strip())
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				cache.append('%s\t%s\t%s' % (package, clean_version, zi_arch))
			else:
				warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})

		self._write_cache(cache)

	def get_package_info(self, package, factory):
		# Add installed versions...
		versions = self.versions.get(package, [])

		for version, machine in versions:
			impl = factory('package:rpm:%s:%s:%s' % (package, version, machine))
			impl.version = model.parse_version(version)
			if machine != '*':
				impl.machine = machine

		# Add any uninstalled candidates found by PackageKit
		self.packagekit.get_candidates(package, factory, 'package:rpm')

	def get_score(self, disto_name):
		return int(disto_name == 'RPM')

class SlackDistribution(Distribution):
	"""A Slack-based distribution."""

	def __init__(self, packages_dir):
		self._packages_dir = packages_dir

	def get_package_info(self, package, factory):
		# Add installed versions...
		for entry in os.listdir(self._packages_dir):
			name, version, arch, build = entry.rsplit('-', 3)
			if name == package:
				zi_arch = canonical_machine(arch)
				clean_version = try_cleanup_distro_version("%s-%s" % (version, build))
				if not clean_version:
					warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': name})
					continue
	
				impl = factory('package:slack:%s:%s:%s' % \
						(package, clean_version, zi_arch))
				impl.version = model.parse_version(clean_version)
				if zi_arch != '*':
					impl.machine = zi_arch

		# Add any uninstalled candidates found by PackageKit
		self.packagekit.get_candidates(package, factory, 'package:slack')

	def get_score(self, disto_name):
		return int(disto_name == 'Slack')

class GentooDistribution(Distribution):

	def __init__(self, pkgdir):
		self._pkgdir = pkgdir

	def get_package_info(self, package, factory):
		# Add installed versions...
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

		# Add any uninstalled candidates found by PackageKit
		self.packagekit.get_candidates(package, factory, 'package:gentoo')

	def get_score(self, disto_name):
		return int(disto_name == 'Gentoo')

class PortsDistribution(Distribution):

	def __init__(self, pkgdir):
		self._pkgdir = pkgdir

	def get_package_info(self, package, factory):
		_name_version_regexp = '^(.+)-([^-]+)$'

		nameversion = re.compile(_name_version_regexp)
		for pkgname in os.listdir(self._pkgdir):
			pkgdir = os.path.join(self._pkgdir, pkgname)
			if not os.path.isdir(pkgdir): continue

			#contents = file(os.path.join(pkgdir, '+CONTENTS')).readline().strip()

			match = nameversion.search(pkgname)
			if match is None:
				warn(_('Cannot parse version from Ports package named "%(pkgname)s"'), {'pkgname': pkgname})
				continue
			else:
				name = match.group(1)
				if name != package:
					continue
				version = try_cleanup_distro_version(match.group(2))

			machine = host_machine

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
		_slack_db = '/var/log/packages'
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
		elif os.path.isdir(_slack_db):
			_host_distribution = SlackDistribution(_slack_db)
		else:
			_host_distribution = Distribution()

	return _host_distribution
