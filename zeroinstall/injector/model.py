# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

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

def _split_arch(arch):
	"""Split an arch into an (os, machine) tuple. Either or both parts may be None."""
	if not arch:
		return None, None
	elif '-' not in arch:
		raise SafeException("Malformed arch '%s'" % arch)
	else:
		os, machine = arch.split('-', 1)
		if os == '*': os = None
		if machine == '*': machine = None
		return os, machine

def _join_arch(os, machine):
	if os == machine == None: return None
	return "%s-%s" % (os or '*', machine or '*')
	
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

class Restriction(object):
	"""A Restriction limits the allowed implementations of an Interface."""
	__slots__ = ['before', 'not_before']
	def __init__(self, before, not_before):
		self.before = before
		self.not_before = not_before
	
	def meets_restriction(self, impl):
		if self.not_before and impl.version < self.not_before:
			return False
		if self.before and impl.version >= self.before:
			return False
		return True
	
	def __str__(self):
		if self.not_before is not None or self.before is not None:
			range = ''
			if self.not_before is not None:
				range += '.'.join(map(str, self.not_before)) + ' <= '
			range += 'version'
			if self.before is not None:
				range += ' < ' + '.'.join(map(str, self.before))
		else:
			range = 'none'
		return "(restriction: %s)" % range

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
	__repr__ = __str__
	
	def get_value(self, path, old_value):
		extra = os.path.join(path, self.insert)
		if old_value is None:
			old_value = self.default or defaults.get(self.name, None)
		if old_value is None:
			return extra
		return extra + ':' + old_value

class Feed(object):
	"""An interface's feeds are other interfaces whose implementations can also be
	used as implementations of this interface."""
	__slots__ = ['uri', 'os', 'machine', 'user_override']
	def __init__(self, uri, arch, user_override):
		self.uri = uri
		# This indicates whether the feed comes from the user's overrides
		# file. If true, writer.py will write it when saving.
		self.user_override = user_override
		self.os, self.machine = _split_arch(arch)
	
	def __str__(self):
		return "<Feed from %s>" % self.uri
	__repr__ = __str__

	arch = property(lambda self: _join_arch(self.os, self.machine))

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
		return "<Dependency on %s; bindings: %s%s>" % (self.interface, self.bindings, self.restrictions)

class RetrievalMethod(object):
	"""A RetrievalMethod provides a way to fetch an implementation."""
	__slots__ = []

class DownloadSource(RetrievalMethod):
	"""A DownloadSource provides a way to fetch an implementation."""
	__slots__ = ['implementation', 'url', 'size', 'extract']

	def __init__(self, implementation, url, size, extract):
		assert url.startswith('http:') or url.startswith('ftp:') or url.startswith('/')
		self.implementation = implementation
		self.url = url
		self.size = size
		self.extract = extract

class Recipe(RetrievalMethod):
	"""Get an implementation by following a series of steps."""
	__slots__ = ['steps']

	def __init__(self):
		self.steps = []
	
	size = property(lambda self: sum([x.size for x in self.steps]))

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
		"""Add a download source."""
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
	
	def set_arch(self, arch):
		self.os, self.machine = _split_arch(arch)
	arch = property(lambda self: _join_arch(self.os, self.machine), set_arch)
	
class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'implementations', 'name', 'description', 'summary',
		     'stability_policy', 'last_modified', 'last_local_update', 'last_checked',
		     'main', 'feeds', 'feed_for', 'metadata']

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
		self.feeds = []
		self.feed_for = {}	# URI -> True
		self.metadata = []
	
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
	
	def get_feed(self, uri):
		for x in self.feeds:
			if x.uri == uri:
				return x
		return None
	
	def add_metadata(self, elem):
		self.metadata.append(elem)
	
	def get_metadata(self, uri, name):
		"""Return a list of interface metadata elements with this name and namespace URI."""
		return [m for m in self.metadata if m.name == name and m.uri == uri]

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
