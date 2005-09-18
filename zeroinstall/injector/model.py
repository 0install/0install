"""In-memory representation of the dependency graph."""

import os
from zeroinstall import SafeException

network_offline = 'off-line'
network_minimal = 'minimal'
network_full = 'full'
network_levels = (network_offline, network_minimal, network_full)

stability_levels = {}	# Name -> Stability

# Default values for the 'default' attribute for <environment> bindings of
# well-known variables:
defaults = {
	'PATH': '/bin:/usr/bin',
	'XDG_CONFIG_DIRS': '/etc/xdg',
	'XDG_DATA_DIRS': '/usr/local/share:/usr/share',
}

class Stability(object):
	__slots__ = ['level', 'name', 'description']
	def __init__(self, level, name, description):
		self.level = level
		self.name = name
		self.description = description
		assert name not in stability_levels
		stability_levels[name] = self
	
	def __cmp__(self, other):
		return cmp(self.level, other.level)
	
	def __str__(self):
		return self.name

insecure = Stability(0, 'insecure', 'This is a security risk')
buggy = Stability(5, 'buggy', 'Known to have serious bugs')
developer = Stability(10, 'developer', 'Work-in-progress - bugs likely')
testing = Stability(20, 'testing', 'Stability unknown - please test!')
stable = Stability(30, 'stable', 'Tested - no serious problems found')
preferred = Stability(40, 'preferred', 'Best of all - must be set manually')

class Source(object):
	"""An interface that can be executed to build a new implementation."""
	__slots__ = ['source_interface']

	def __init__(self, source_interface):
		self.source_interface = source_interface

class Restriction(object):
	"""A Restriction limits the allowed implementations of an Interface."""

class Binding(object):
	"""Information about how the choice of a Dependency is made known
	to the application being run."""

class EnvironmentBinding(Binding):
	__slots__ = ['name', 'insert', 'default']

	def __init__(self, name, insert, default = None):
		self.name = name
		self.insert = insert
		self.default = default
	
	def __str__(self):
		return "<environ %s += %s>" % (self.name, self.insert)
	
	def get_value(self, path, old_value):
		extra = os.path.join(path, self.insert)
		if old_value is None:
			old_value = self.default or defaults.get(self.name, None)
		if old_value is None:
			return extra
		return extra + ':' + old_value

class Dependency(object):
	"""A Dependency indicates that an Implementation requires some additional
	code to function, specified by another Interface."""
	__slots__ = ['interface', 'restrictions', 'bindings']

	def __init__(self, interface):
		assert isinstance(interface, (str, unicode))
		assert interface
		self.interface = interface
		self.restrictions = []
		self.bindings = []
	
	def __str__(self):
		return "<Dependency on %s; bindings: %d>" % (self.interface, len(self.bindings))

class DownloadSource(object):
	"""A DownloadSource provides a way to fetch an implementation."""
	__slots__ = ['implementation', 'url', 'size', 'extract']

	def __init__(self, implementation, url, size, extract):
		assert url.startswith('http:') or url.startswith('ftp:') or url.startswith('/')
		self.implementation = implementation
		self.url = url
		self.size = size
		self.extract = extract

class Implementation(object):
	"""An Implementation is a package which implements an Interface."""
	__slots__ = ['os', 'machine', 'upstream_stability', 'user_stability',
		     'version', 'size', 'dependencies', 'main',
		     'id', 'download_sources', 'released', 'interface']

	def __init__(self, interface, id):
		"""id can be a local path (string starting with /) or a manifest hash (eg "sha1=XXX")"""
		assert id
		self.interface = interface
		self.id = id
		self.main = None
		self.size = None
		self.version = None
		self.released = None
		self.user_stability = None
		self.upstream_stability = None
		self.os = None
		self.machine = None
		self.dependencies = {}	# URI -> Dependency
		self.download_sources = []	# [DownloadSource]
	
	def add_download_source(self, url, size, extract):
		self.download_sources.append(DownloadSource(self, url, size, extract))
	
	def get_stability(self):
		return self.user_stability or self.upstream_stability or testing
	
	def get_version(self):
		return '.'.join(map(str, self.version))
	
	def __str__(self):
		return self.id

	def __cmp__(self, other):
		"""Newer versions come first"""
		return cmp(other.version, self.version)
	
	def get_arch(self):
		if self.os is not None:
			return self.os + "-" + self.machine
		return None
	
	def set_arch(self, arch):
		if arch is None:
			self.os = self.machine = None
		elif '-' not in arch:
			raise SafeException("Malformed arch '%s'", arch)
		else:
			self.os, self.machine = arch.split('-', 1)
	arch = property(get_arch, set_arch)
	
class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'implementations', 'name', 'description', 'summary',
		     'stability_policy', 'last_modified', 'last_local_update', 'last_checked',
		     'main', 'feeds', 'sources']

	# last_local_update is deprecated
	
	# stability_policy:
	# Implementations at this level or higher are preferred.
	# Lower levels are used only if there is no other choice.

	def __init__(self, uri):
		assert uri
		if uri.startswith('http:') or uri.startswith('/'):
			self.uri = uri
			self.reset()
		else:
			raise SafeException("Interface name '%s' doesn't start "
					    "with 'http:'" % uri)

	def reset(self):
		self.implementations = {}	# Path -> Implementation
		self.name = None
		self.summary = None
		self.description = None
		self.stability_policy = None
		self.last_modified = None
		self.last_local_update = None
		self.last_checked = None
		self.main = None
		self.sources = []
		self.feeds = []
	
	def get_name(self):
		return self.name or '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri
	
	def get_impl(self, id):
		if id not in self.implementations:
			self.implementations[id] = Implementation(self, id)
		return self.implementations[id]
	
	def set_stability_policy(self, new):
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new

def unescape(uri):
	"Convert each %20 to a space, etc"
	if '%' not in uri: return uri
	import re
	return re.sub('%[0-9a-fA-F][0-9a-fA-F]',
		lambda match: chr(int(match.group(0)[1:], 16)),
		uri)

def escape(uri):
	"Convert each space to %20, etc"
	import re
	return re.sub('[^-_.a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8'))

def canonical_iface_uri(uri):
	if uri.startswith('http:'):
		return uri
	else:
		iface_uri = os.path.realpath(uri)
		if os.path.isfile(iface_uri):
			return iface_uri
	raise SafeException("Bad interface name '%s'.\n"
			"(doesn't start with 'http:', and "
			"doesn't exist as a local file '%s' either)" %
			(uri, iface_uri))
