"""
Integration with native distribution package managers.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import os, platform, re, subprocess, sys
from zeroinstall.injector import namespaces, model
from zeroinstall.support import basedir, portable_rename, intern

_dotted_ints = '[0-9]+(?:\.[0-9]+)*'

# This matches a version number that would be a valid Zero Install version without modification
_zeroinstall_regexp = '(?:%s)(?:-(?:pre|rc|post|)(?:%s))*' % (_dotted_ints, _dotted_ints)

# This matches the interesting bits of distribution version numbers
# (first matching group is for Java-style 6b17 or 7u9 syntax, or "major")
_version_regexp = '(?:[a-z])?({ints}\.?[bu])?({zero})(-r{ints})?'.format(zero = _zeroinstall_regexp, ints = _dotted_ints)

def _set_quick_test(impl, path):
	"""Set impl.quick_test_file and impl.quick_test_mtime from path."""
	impl.quick_test_file = path
	impl.quick_test_mtime = int(os.stat(path).st_mtime)

def try_cleanup_distro_version(version):
	"""Try to turn a distribution version string into one readable by Zero Install.
	We do this by stripping off anything we can't parse.
	@type version: str
	@return: the part we understood, or None if we couldn't parse anything
	@rtype: str"""
	if ':' in version:
		version = version.split(':')[1]	# Skip 'epoch'
	version = version.replace('_', '-')
	if '~' in version:
		version, suffix = version.split('~', 1)
		if suffix.startswith('pre'):
			suffix = suffix[3:]
		suffix = '-pre' + (try_cleanup_distro_version(suffix) or '')
	else:
		suffix = ''
	match = re.match(_version_regexp, version)
	if match:
		major, version, revision = match.groups()
		if major is not None:
			version = major[:-1].rstrip('.') + '.' + version
		if revision is not None:
			version = '%s-%s' % (version, revision[2:])
		return version + suffix
	return None

class Distribution(object):
	"""Represents a distribution with which we can integrate.
	Sub-classes should specialise this to integrate with the package managers of
	particular distributions. This base class ignores the native package manager.
	@since: 0.28
	@ivar name: the default value for Implementation.distro_name for our implementations
	@type name: str
	@ivar system_paths: list of paths to search for binaries (we MUST NOT find 0install launchers, so only include directories where system packages install binaries - e.g. /usr/bin but not /usr/local/bin)
	@type system_paths: [str]
	"""

	name = "fallback"

	system_paths = ['/usr/bin', '/bin', '/usr/sbin', '/sbin']

	def get_package_info(self, package, factory):
		"""Get information about the given package.
		Add zero or more implementations using the factory (typically at most two
		will be added; the currently installed version and the latest available).
		@param package: package name (e.g. "gimp")
		@type package: str
		@param factory: function for creating new DistributionImplementation objects from IDs
		@type factory: str -> L{model.DistributionImplementation}"""
		return

	def get_score(self, distribution):
		"""Indicate how closely the host distribution matches this one.
		The <package-implementation> with the highest score is passed
		to L{Distribution.get_package_info}. If several elements get
		the same score, get_package_info is called for all of them.
		@param distribution: a distribution name
		@type distribution: str
		@return: an integer, or -1 if there is no match at all
		@rtype: int"""
		return 0

	def get_feed(self, master_feed_url, package_impls):
		"""Generate a feed containing information about distribution packages.
		This should immediately return a feed containing an implementation for the
		package if it's already installed. Information about versions that could be
		installed using the distribution's package manager can be added asynchronously
		later (see L{fetch_candidates}).
		@rtype: L{model.ZeroInstallFeed}"""

		feed = model.ZeroInstallFeed(None)
		feed.url = 'distribution:' + master_feed_url

		for item, item_attrs, _depends in package_impls:
			package = item_attrs.get('package', None)
			if package is None:
				raise model.InvalidInterface(_("Missing 'package' attribute on %s") % item)

			new_impls = []

			def factory(id, only_if_missing = False, installed = True):
				assert id.startswith('package:')
				if id in feed.implementations:
					if only_if_missing:
						return None
					logger.warning(_("Duplicate ID '%s' for DistributionImplementation"), id)
				impl = model.DistributionImplementation(feed, id, self, item)
				feed.implementations[id] = impl
				new_impls.append(impl)

				impl.installed = installed
				impl.metadata = item_attrs

				if impl.main is None:
					item_main = item_attrs.get('main', None)
					if item_main:
						impl.main = item_main
				impl.upstream_stability = model.packaged

				return impl

			self.get_package_info(package, factory)

			for impl in new_impls:
				self.fixup(package, impl)
				if impl.installed:
					self.installed_fixup(impl)

		return feed

	def fixup(self, package, impl):
		"""Some packages require special handling (e.g. Java). This is called for each
		package that was added by L{get_package_info} after it returns. The default
		method does nothing.
		@param package: the name of the package
		@param impl: the constructed implementation"""
		pass

	def installed_fixup(self, impl):
		"""Called when an installed package is added (after L{fixup}), or when installation
		completes. This is useful to fix up the main value.
		The default implementation checks that main exists, and searches L{Distribution.system_paths} for
		it if not.
		@type impl: L{DistributionImplementation}
		@since: 1.11"""

		path = impl.main

		if not path: return

		if os.path.isabs(path) and os.path.exists(path):
			return

		basename = os.path.basename(path)
		if os.name == "nt" and not basename.endswith('.exe'):
			basename += '.exe'

		for d in self.system_paths:
			path = os.path.join(d, basename)
			if os.path.isfile(path):
				logger.info("Found %s by searching system paths", path)
				impl.main = path
				return
		else:
			logger.info("Binary '%s' not found in any system path (checked %s)", basename, self.system_paths)

	def get_score(self, distro_name):
		"""@type distro_name: str
		@rtype: int"""
		return int(distro_name == self.name)

class DarwinDistribution(Distribution):
	"""@since: 1.11"""

	name = 'Darwin'

	def get_package_info(self, package, factory):
		"""@type package: str"""
		def java_home(version, arch):
			null = os.open(os.devnull, os.O_WRONLY)
			child = subprocess.Popen(["/usr/libexec/java_home", "--failfast", "--version", version, "--arch", arch],
							stdout = subprocess.PIPE, stderr = null, universal_newlines = True)
			home = child.stdout.read().strip()
			child.stdout.close()
			child.wait()
			return home

		def find_java(part, jvm_version, zero_version):
			for arch in ['i386', 'x86_64']:
				home = java_home(jvm_version, arch)
				if os.path.isfile(home + "/bin/java"):
					impl = factory('package:darwin:%s:%s:%s' % (package, zero_version, arch))
					impl.machine = arch
					impl.version = model.parse_version(zero_version)
					impl.upstream_stability = model.packaged
					impl.main = home + "/bin/java"
					_set_quick_test(impl, impl.main)

		if package == 'openjdk-6-jre':
			find_java("Java Runtime Environment", "1.6", '6')
		elif package == 'openjdk-6-jdk':
			find_java("Java Development Kit", "1.6", '6')
		elif package == 'openjdk-7-jre':
			find_java("Java Runtime Environment", "1.7", '7')
		elif package == 'openjdk-7-jdk':
			find_java("Java Development Kit", "1.7", '7')

		def get_output(args):
			child = subprocess.Popen(args, stdout = subprocess.PIPE, universal_newlines = True)
			return child.communicate()[0]

		def get_version(program):
			stdout = get_output([program, "--version"])
			return stdout.strip().split('\n')[0].split()[-1] # the last word of the first line

		def find_program(file):
			if os.path.isfile(file) and os.access(file, os.X_OK):
				program_version = try_cleanup_distro_version(get_version(file))
				impl = factory('package:darwin:%s:%s' % (package, program_version), True)
				if impl:
					impl.installed = True
					impl.version = model.parse_version(program_version)
					impl.upstream_stability = model.packaged
					impl.machine = host_machine	# (hopefully)
					impl.main = file
					_set_quick_test(impl, impl.main)

		if package == 'gnupg':
			find_program("/usr/local/bin/gpg")
		elif package == 'gnupg2':
			find_program("/usr/local/bin/gpg2")

class CachedDistribution(Distribution):
	"""For distributions where querying the package database is slow (e.g. requires running
	an external command), we cache the results.
	@since: 0.39
	@deprecated: use Cache instead
	"""

	def __init__(self, db_status_file):
		"""@param db_status_file: update the cache when the timestamp of this file changes
		@type db_status_file: str"""
		self._status_details = os.stat(db_status_file)

		self.versions = {}
		self.cache_dir = basedir.save_cache_path(namespaces.config_site,
							 namespaces.config_prog)

		try:
			self._load_cache()
		except Exception as ex:
			logger.info(_("Failed to load distribution database cache (%s). Regenerating..."), ex)
			try:
				self.generate_cache()
				self._load_cache()
			except Exception as ex:
				logger.warning(_("Failed to regenerate distribution database cache: %s"), ex)

	def _load_cache(self):
		"""Load {cache_leaf} cache file into self.versions if it is available and up-to-date.
		Throws an exception if the cache should be (re)created."""
		with open(os.path.join(self.cache_dir, self.cache_leaf), 'rt') as stream:
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
		"""@type cache: [str]"""
		import tempfile
		fd, tmpname = tempfile.mkstemp(prefix = 'zeroinstall-cache-tmp',
					       dir = self.cache_dir)
		try:
			stream = os.fdopen(fd, 'wt')
			stream.write('version: 2\n')
			stream.write('mtime: %d\n' % int(self._status_details.st_mtime))
			stream.write('size: %d\n' % self._status_details.st_size)
			stream.write('\n')
			for line in cache:
				stream.write(line + '\n')
			stream.close()

			portable_rename(tmpname,
				  os.path.join(self.cache_dir,
					       self.cache_leaf))
		except:
			os.unlink(tmpname)
			raise

# Maps machine type names used in packages to their Zero Install versions
# (updates to this might require changing the reverse Java mapping)
_canonical_machine = {
	'all' : '*',
	'any' : '*',
	'noarch' : '*',
	'(none)' : '*',
	'x86_64': 'x86_64',
	'amd64': 'x86_64',
	'i386': 'i386',
	'i486': 'i486',
	'i586': 'i586',
	'i686': 'i686',
	'ppc64': 'ppc64',
	'ppc': 'ppc',
}

def arch_canonicalize_machine(machine_):
	"""@type machine_: str
	@rtype: str"""
	machine = machine_.lower()
	if machine == 'x86':
		machine = 'i386'
	elif machine == 'amd64':
		machine = 'x86_64'
	elif machine == 'Power Macintosh':
		machine = 'ppc'
	elif machine == 'i86pc':
		machine = 'i686'
	return machine

host_machine = arch_canonicalize_machine(platform.uname()[4])
def canonical_machine(package_machine):
	"""@type package_machine: str
	@rtype: str"""
	machine = _canonical_machine.get(package_machine.lower(), None)
	if machine is None:
		# Safe default if we can't understand the arch
		return host_machine.lower()
	return machine

class MacPortsDistribution(CachedDistribution):
	system_paths = ['/opt/local/bin']

	name = 'MacPorts'

	def __init__(self, db_status_file):
		"""@type db_status_file: str"""
		super(MacPortsDistribution, self).__init__(db_status_file)
		self.darwin = DarwinDistribution()

	cache_leaf = 'macports-status.cache'

	def generate_cache(self):
		cache = []

		child = subprocess.Popen(["port", "-v", "installed"],
					  stdout = subprocess.PIPE, universal_newlines = True)
		for line in child.stdout:
			if not line.startswith(" "):
				continue
			if line.strip().count(" ") > 1:
				package, version, extra = line.split(None, 2)
			else:
				package, version = line.split()
				extra = ""
			if not extra.startswith("(active)"):
				continue
			version = version.lstrip('@')
			version = re.sub(r"\+.*", "", version) # strip variants
			zi_arch = '*'
			clean_version = try_cleanup_distro_version(version)
			if clean_version:
				match = re.match(r" platform='([^' ]*)( \d+)?' archs='([^']*)'", extra)
				if match:
					platform, major, archs = match.groups()
					for arch in archs.split():
						zi_arch = canonical_machine(arch)
						cache.append('%s\t%s\t%s' % (package, clean_version, zi_arch))
				else:
					cache.append('%s\t%s\t%s' % (package, clean_version, zi_arch))
			else:
				logger.warning(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package})
		self._write_cache(cache)
		child.stdout.close()
		child.wait()

	def get_package_info(self, package, factory):
		"""@type package: str"""
		self.darwin.get_package_info(package, factory)

		# Add installed versions...
		versions = self.versions.get(package, [])

		for version, machine in versions:
			impl = factory('package:macports:%s:%s:%s' % (package, version, machine))
			impl.version = model.parse_version(version)
			if machine != '*':
				impl.machine = machine

	def get_score(self, distro_name):
		# We support both sources of packages.
		# In theory, we should route 'Darwin' package names to DarwinDistribution, and
		# Mac Ports names to MacPortsDistribution. But since we only use Darwin for Java,
		# having one object handle both is OK.
		return int(distro_name in ('Darwin', 'MacPorts'))
