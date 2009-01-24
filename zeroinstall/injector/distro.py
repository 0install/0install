"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, re
from logging import warn, info
from zeroinstall.injector import namespaces, model
from zeroinstall.support import basedir

_dotted_ints = '[0-9]+(\.[0-9]+)*'
_version_regexp = '(%s)(-(pre|rc|post|)%s)*' % (_dotted_ints, _dotted_ints)

def try_cleanup_distro_version(version):
	"""Try to turn a distribution version string into one readable by Zero Install.
	We do this by stripping off anything we can't parse.
	@return: the part we understood, or None if we couldn't parse anything
	@rtype: str"""
	match = re.match(_version_regexp, version)
	if match:
		return match.group(0)
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

class DebianDistribution(Distribution):
	"""An dpkg-based distribution."""

	cache_leaf = 'dpkg-status.cache'

	def __init__(self, db_status_file):
		self.status_details = os.stat(db_status_file)

		self.versions = {}
		self.cache_dir = basedir.save_cache_path(namespaces.config_site, namespaces.config_prog)

		try:
			self.load_cache()
		except Exception, ex:
			info("Failed to load dpkg cache (%s). Regenerating...", ex)
			try:
				self.generate_cache()
				self.load_cache()
			except Exception, ex:
				warn("Failed to regenerate dpkg cache: %s", ex)

	def load_cache(self):
		stream = file(os.path.join(self.cache_dir, self.cache_leaf))

		cache_version = None
		for line in stream:
			if line == '\n':
				break
			name, value = line.split(': ')
			if name == 'mtime' and int(value) != int(self.status_details.st_mtime):
				raise Exception("Modification time of dpkg status file has changed")
			if name == 'size' and int(value) != self.status_details.st_size:
				raise Exception("Size of dpkg status file has changed")
			if name == 'version':
				cache_version = int(value)
		else:
			raise Exception('Invalid cache format (bad header)')

		if cache_version is None:
			raise Exception('Old cache format')
			
		versions = self.versions
		for line in stream:
			package, version, zi_arch = line[:-1].split('\t')
			versions[package] = (version, intern(zi_arch))

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
				warn("Can't parse distribution version '%s' for package '%s'", version, package)

		cache.sort() 	# Might be useful later; currently we don't care
		
		import tempfile
		fd, tmpname = tempfile.mkstemp(prefix = 'dpkg-cache-tmp', dir = self.cache_dir)
		try:
			stream = os.fdopen(fd, 'wb')
			stream.write('version: 2\n')
			stream.write('mtime: %d\n' % int(self.status_details.st_mtime))
			stream.write('size: %d\n' % self.status_details.st_size)
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

	def get_package_info(self, package, factory):
		try:
			version, machine = self.versions[package]
		except KeyError:
			return

		impl = factory('package:deb:%s:%s' % (package, version)) 
		impl.version = model.parse_version(version)
		if machine != '*':
			impl.machine = machine

class RPMDistribution(Distribution):
	"""An RPM-based distribution."""

	cache_leaf = 'rpm-status.cache'
	
	def __init__(self, packages_file):
		self.status_details = os.stat(packages_file)

		self.versions = {}
		self.cache_dir=basedir.save_cache_path(namespaces.config_site,
						       namespaces.config_prog)

		try:
			self.load_cache()
		except Exception, ex:
			info("Failed to load cache (%s). Regenerating...",
			     ex)
			try:
				self.generate_cache()
				self.load_cache()
			except Exception, ex:
				warn("Failed to regenerate cache: %s", ex)

	def load_cache(self):
		stream = file(os.path.join(self.cache_dir, self.cache_leaf))

		for line in stream:
			if line == '\n':
				break
			name, value = line.split(': ')
			if name == 'mtime' and (int(value) !=
					    int(self.status_details.st_mtime)):
				raise Exception("Modification time of rpm status file has changed")
			if name == 'size' and (int(value) !=
					       self.status_details.st_size):
				raise Exception("Size of rpm status file has changed")
		else:
			raise Exception('Invalid cache format (bad header)')
			
		versions = self.versions
		for line in stream:
			package, version = line[:-1].split('\t')
			versions[package] = version

	def __parse_rpm_name(self, line):
		"""Some samples we have to cope with (from SuSE 10.2):
		mp3blaster-3.2.0-0.pm0
		fuse-2.5.2-2.pm.0
		gpg-pubkey-1abd1afb-450ef738
		a52dec-0.7.4-3.pm.1
		glibc-html-2.5-25
		gnome-backgrounds-2.16.1-14
		gnome-icon-theme-2.16.0.1-12
		opensuse-quickstart_en-10.2-9
		susehelp_en-2006.06.20-25
		yast2-schema-2.14.2-3"""

		parts=line.strip().split('-')
		if len(parts)==2:
			return parts[0], try_cleanup_distro_version(parts[1])

		elif len(parts)<2:
			return None, None

		package='-'.join(parts[:-2])
		version=parts[-2]
		mod=parts[-1]

		return package, try_cleanup_distro_version(version+'-'+mod)
		
	def generate_cache(self):
		cache = []

		for line in os.popen("rpm -qa"):
			package, version = self.__parse_rpm_name(line)
			if package and version:
				cache.append('%s\t%s' % (package, version))

		cache.sort()   # Might be useful later; currently we don't care
		
		import tempfile
		fd, tmpname = tempfile.mkstemp(prefix = 'rpm-cache-tmp',
					       dir = self.cache_dir)
		try:
			stream = os.fdopen(fd, 'wb')
			stream.write('mtime: %d\n' % int(self.status_details.st_mtime))
			stream.write('size: %d\n' % self.status_details.st_size)
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

	def get_package_info(self, package, factory):
		try:
			version = self.versions[package]
		except KeyError:
			return

		impl = factory('package:rpm:%s:%s' % (package, version)) 
		impl.version = model.parse_version(version)

_host_distribution = None
def get_host_distribution():
	"""Get a Distribution suitable for the host operating system.
	Calling this twice will return the same object.
	@rtype: L{Distribution}"""
	global _host_distribution
	if not _host_distribution:
		_dpkg_db_status = '/var/lib/dpkg/status'
		_rpm_db = '/var/lib/rpm/Packages'

		if os.access(_dpkg_db_status, os.R_OK):
			_host_distribution = DebianDistribution(_dpkg_db_status)
		elif os.path.isfile(_rpm_db):
			_host_distribution = RPMDistribution(_rpm_db)
		else:
			_host_distribution = Distribution()
	
	return _host_distribution
