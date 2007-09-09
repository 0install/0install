"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, re
from logging import warn, info
from zeroinstall.injector import namespaces, basedir, model

dotted_ints = '[0-9]+(\.[0-9]+)*'
version_regexp = '(%s)(-(pre|rc|post|)%s)*' % (dotted_ints, dotted_ints)

def try_cleanup_distro_version(version):
	"""Try to turn a distribution version string into one readable by Zero Install.
	We do this by stripping off anything we can't parse.
	@return: the part we understood, or None if we couldn't parse anything
	@rtype: str"""
	match = re.match(version_regexp, version)
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
	def __init__(self, db_dir):
		self.db_dir = db_dir
		dpkg_status = db_dir + '/status'
		self.status_details = os.stat(self.db_dir + '/status')

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
		stream = file(self.cache_dir + '/dpkg-status.cache')

		for line in stream:
			if line == '\n':
				break
			name, value = line.split(': ')
			if name == 'mtime' and int(value) != int(self.status_details.st_mtime):
				raise Exception("Modification time of dpkg status file has changed")
			if name == 'size' and int(value) != self.status_details.st_size:
				raise Exception("Size of dpkg status file has changed")
		else:
			raise Exception('Invalid cache format (bad header)')
			
		versions = self.versions
		for line in stream:
			package, version = line[:-1].split('\t')
			versions[package] = version

	def generate_cache(self):
		cache = []

		for line in os.popen("dpkg-query -W"):
			package, version = line.split('\t', 1)
			if ':' in version:
				# Debian's 'epoch' system
				version = version.split(':', 1)[1]
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				cache.append('%s\t%s' % (package, clean_version))
			else:
				warn("Can't parse distribution version '%s' for package '%s'", version, package)

		cache.sort() 	# Might be useful later; currently we don't care
		
		import tempfile
		fd, tmpname = tempfile.mkstemp(prefix = 'dpkg-cache-tmp', dir = self.cache_dir)
		try:
			stream = os.fdopen(fd, 'wb')
			stream.write('mtime: %d\n' % int(self.status_details.st_mtime))
			stream.write('size: %d\n' % self.status_details.st_size)
			stream.write('\n')
			for line in cache:
				stream.write(line + '\n')
			stream.close()

			os.rename(tmpname, self.cache_dir + '/dpkg-status.cache')
		except:
			os.unlink(tmpname)
			raise

	def get_package_info(self, package, factory):
		try:
			version = self.versions[package]
		except KeyError:
			return

		impl = factory('package:deb:%s:%s' % (package, version)) 
		impl.version = model.parse_version(version)

_dpkg_db_dir = '/var/lib/dpkg'
if os.path.isdir(_dpkg_db_dir):
	host_distribution = DebianDistribution(_dpkg_db_dir)
else:
	host_distribution = Distribution()
