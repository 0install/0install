"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, re, glob
from logging import warn, info
from zeroinstall.injector import namespaces, model
from zeroinstall.support import basedir

_dotted_ints = '[0-9]+(?:\.[0-9]+)*'

# This matches a version number that would be a valid Zero Install version without modification
_zeroinstall_regexp = '(?:%s)(?:-(?:pre|rc|post|)(?:%s))*' % (_dotted_ints, _dotted_ints)

# This matches the interesting bits of distribution version numbers
_version_regexp = '(%s)(-r%s)?' % (_zeroinstall_regexp, _dotted_ints)

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

class CachedDistribution(Distribution):
	"""For distributions where querying the package database is slow (e.g. requires running
	an external command), we cache the results.
	@since: 0.39
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

class DebianDistribution(CachedDistribution):
	"""A dpkg-based distribution."""

	cache_leaf = 'dpkg-status.cache'

	def generate_cache(self):
		cache = []

		for line in os.popen("dpkg-query -W --showformat='${Package}\t${Version}\t${Architecture}\n'"):
			package, version, debarch = line.split('\t', 2)
			if ':' in version:
				# Debian's 'epoch' system
				version = version.split(':', 1)[1]
			if debarch == 'amd64\n':
				zi_arch = 'x86_64'
			else:
				zi_arch = '*'
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				cache.append('%s\t%s\t%s' % (package, clean_version, zi_arch))
			else:
				warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})

		self._write_cache(cache)

	def get_package_info(self, package, factory):
		try:
			version, machine = self.versions[package][0]
		except KeyError:
			return

		impl = factory('package:deb:%s:%s' % (package, version)) 
		impl.version = model.parse_version(version)
		if machine != '*':
			impl.machine = machine

	def get_score(self, disto_name):
		return int(disto_name == 'Debian')

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

				machine = file(os.path.join(category_dir, filename, 'CHOST')).readline().split('-')[0]

				impl = factory('package:gentoo:%s:%s:%s' % \
						(package, version, machine))
				impl.version = model.parse_version(version)

	def get_score(self, disto_name):
		return int(disto_name == 'Gentoo')


_host_distribution = None
def get_host_distribution():
	"""Get a Distribution suitable for the host operating system.
	Calling this twice will return the same object.
	@rtype: L{Distribution}"""
	global _host_distribution
	if not _host_distribution:
		_dpkg_db_status = '/var/lib/dpkg/status'
		_rpm_db = '/var/lib/rpm/Packages'
		_gentoo_db = '/var/db/pkg'

		if os.path.isdir(_gentoo_db):
			_host_distribution = GentooDistribution(_gentoo_db)
		elif os.access(_dpkg_db_status, os.R_OK):
			_host_distribution = DebianDistribution(_dpkg_db_status)
		elif os.path.isfile(_rpm_db):
			_host_distribution = RPMDistribution(_rpm_db)
		else:
			_host_distribution = Distribution()
	
	return _host_distribution
