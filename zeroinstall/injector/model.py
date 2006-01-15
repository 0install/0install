"""In-memory representation of interfaces and other data structures.

The objects in this module are used to build a representation of an XML interface
file in memory.

@see: L{reader} constructs these data-structures.

@var defaults: Default values for the 'default' attribute for <environment> bindings of
well-known variables.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, re
from zeroinstall import SafeException
import namespaces

network_offline = 'off-line'
network_minimal = 'minimal'
network_full = 'full'
network_levels = (network_offline, network_minimal, network_full)

stability_levels = {}	# Name -> Stability

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
	"""A stability rating. Each implementation has an upstream stability rating and,
	optionally, a user-set rating."""
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

	def __repr__(self):
		return "<Stability: " + self.description + ">"

insecure = Stability(0, 'insecure', 'This is a security risk')
buggy = Stability(5, 'buggy', 'Known to have serious bugs')
developer = Stability(10, 'developer', 'Work-in-progress - bugs likely')
testing = Stability(20, 'testing', 'Stability unknown - please test!')
stable = Stability(30, 'stable', 'Tested - no serious problems found')
packaged = Stability(35, 'packaged', 'Supplied by the local package manager')
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
				range += format_version(self.not_before) + ' <= '
			range += 'version'
			if self.before is not None:
				range += ' < ' + format_version(self.before)
		else:
			range = 'none'
		return "(restriction: %s)" % range

class Binding(object):
	"""Information about how the choice of a Dependency is made known
	to the application being run."""

class EnvironmentBinding(Binding):
	"""Indicate the chosen implementation using an environment variable."""
	__slots__ = ['name', 'insert', 'default', 'mode']

	PREPEND = 'prepend'
	APPEND = 'append'
	REPLACE = 'replace'

	def __init__(self, name, insert, default = None, mode = PREPEND):
		"""mode argument added in version 0.28"""
		self.name = name
		self.insert = insert
		self.default = default
		self.mode = mode
	
	def __str__(self):
		return "<environ %s %s %s>" % (self.name, self.mode, self.insert)

	__repr__ = __str__
	
	def get_value(self, path, old_value):
		"""Calculate the new value of the environment variable after applying this binding.
		@param path: the path to the selected implementation
		@param old_value: the current value of the environment variable
		@return: the new value for the environment variable"""
		extra = os.path.join(path, self.insert)

		if self.mode == EnvironmentBinding.REPLACE:
			return extra

		if old_value is None:
			old_value = self.default or defaults.get(self.name, None)
		if old_value is None:
			return extra
		if self.mode == EnvironmentBinding.PREPEND:
			return extra + ':' + old_value
		else:
			return old_value + ':' + extra

	def _toxml(self, doc):
		"""Create a DOM element for this binding.
		@param doc: document to use to create the element
		@return: the new element
		"""
		env_elem = doc.createElementNS(namespaces.XMLNS_IFACE, 'environment')
		env_elem.setAttributeNS(None, 'name', self.name)
		env_elem.setAttributeNS(None, 'insert', self.insert)
		if self.default:
			env_elem.setAttributeNS(None, 'default', self.default)
		return env_elem

class Feed(object):
	"""An interface's feeds are other interfaces whose implementations can also be
	used as implementations of this interface."""
	__slots__ = ['uri', 'os', 'machine', 'user_override', 'langs']
	def __init__(self, uri, arch, user_override, langs = None):
		self.uri = uri
		# This indicates whether the feed comes from the user's overrides
		# file. If true, writer.py will write it when saving.
		self.user_override = user_override
		self.os, self.machine = _split_arch(arch)
		self.langs = langs
	
	def __str__(self):
		return "<Feed from %s>" % self.uri
	__repr__ = __str__

	arch = property(lambda self: _join_arch(self.os, self.machine))

class Dependency(object):
	"""A Dependency indicates that an Implementation requires some additional
	code to function. This is an abstract base class.
	@ivar metadata: any extra attributes from the XML element
	@type metadata: {str: str}
	"""
	__slots__ = ['metadata']

	def __init__(self, metadata):
		if metadata is None:
			metadata = {}
		else:
			assert not isinstance(metadata, basestring)	# Use InterfaceDependency instead!
		self.metadata = metadata

class InterfaceDependency(Dependency):
	"""A Dependency on a Zero Install interface.
	@ivar interface: the interface required by this dependency
	@type interface: str
	@ivar restrictions: a list of constraints on acceptable implementations
	@type restrictions: [L{Restriction}]
	@ivar bindings: how to make the choice of implementation known
	@type bindings: [L{Binding}]
	@since: 0.28
	"""
	__slots__ = ['interface', 'restrictions', 'bindings', 'metadata']

	def __init__(self, interface, restrictions = None, metadata = None):
		Dependency.__init__(self, metadata)
		assert isinstance(interface, (str, unicode))
		assert interface
		self.interface = interface
		if restrictions is None:
			self.restrictions = []
		else:
			self.restrictions = restrictions
		self.bindings = []
	
	def __str__(self):
		return "<Dependency on %s; bindings: %s%s>" % (self.interface, self.bindings, self.restrictions)

class RetrievalMethod(object):
	"""A RetrievalMethod provides a way to fetch an implementation."""
	__slots__ = []

class DownloadSource(RetrievalMethod):
	"""A DownloadSource provides a way to fetch an implementation."""
	__slots__ = ['implementation', 'url', 'size', 'extract', 'start_offset', 'type']

	def __init__(self, implementation, url, size, extract, start_offset = 0, type = None):
		assert url.startswith('http:') or url.startswith('ftp:') or url.startswith('/')
		self.implementation = implementation
		self.url = url
		self.size = size
		self.extract = extract
		self.start_offset = start_offset
		self.type = type		# MIME type - see unpack.py

class Recipe(RetrievalMethod):
	"""Get an implementation by following a series of steps.
	@ivar size: the combined download sizes from all the steps
	@type size: int
	@ivar steps: the sequence of steps which must be performed
	@type steps: [L{RetrievalMethod}]"""
	__slots__ = ['steps']

	def __init__(self):
		self.steps = []
	
	size = property(lambda self: sum([x.size for x in self.steps]))

class Implementation(object):
	"""An Implementation is a package which implements an Interface.
	@ivar download_sources: list of methods of getting this implementation
	@type download_sources: [L{RetrievalMethod}]
	"""

	__slots__ = ['upstream_stability', 'user_stability', 'langs',
		     'requires', 'main', 'metadata', 'download_sources',
		     'id', 'interface', 'version', 'released']

	def __init__(self, interface, id):
		assert id
		self.interface = interface
		self.id = id
		self.main = None
		self.user_stability = None
		self.upstream_stability = None
		self.metadata = {}	# [URI + " "] + localName -> value
		self.requires = []
		self.version = None
		self.released = None
		self.download_sources = []
		self.langs = None

	def get_stability(self):
		return self.user_stability or self.upstream_stability or testing
	
	def __str__(self):
		return self.id

	def __cmp__(self, other):
		"""Newer versions come first"""
		return cmp(other.version, self.version)

	def get_version(self):
		"""Return the version as a string.
		@see: L{format_version}
		"""
		return format_version(self.version)

	arch = property(lambda self: _join_arch(self.os, self.machine))

	os = machine = None

class DistributionImplementation(Implementation):
	"""An implementation provided by the distribution. Information such as the version
	comes from the package manager.
	@since: 0.28"""
	__slots__ = ['installed']

	def __init__(self, interface, id):
		assert id.startswith('package:')
		Implementation.__init__(self, interface, id)
		self.installed = True
	
class ZeroInstallImplementation(Implementation):
	"""An implementation where all the information comes from Zero Install.
	@ivar bindings: how to tell this component where it itself is located (since 0.31)
	@type bindings: [Binding]
	@since: 0.28"""
	__slots__ = ['os', 'machine', 'upstream_stability', 'user_stability',
		     'size', 'requires', 'main', 'metadata', 'bindings',
		     'id',  'interface']

	def __init__(self, interface, id):
		"""id can be a local path (string starting with /) or a manifest hash (eg "sha1=XXX")"""
		Implementation.__init__(self, interface, id)
		self.size = None
		self.os = None
		self.machine = None
		self.bindings = []

	# Deprecated
	dependencies = property(lambda self: dict([(x.interface, x) for x in self.requires
						   if isinstance(x, InterfaceDependency)]))
	
	def add_download_source(self, url, size, extract, start_offset = 0, type = None):
		"""Add a download source."""
		self.download_sources.append(DownloadSource(self, url, size, extract, start_offset, type))
	
	def set_arch(self, arch):
		self.os, self.machine = _split_arch(arch)
	arch = property(lambda self: _join_arch(self.os, self.machine), set_arch)
	
class Interface(object):
	"""An Interface represents some contract of behaviour.
	Note: This class is for both feeds and interfaces. Should really have used separate classes.
	@ivar uri: the URL for this feed
	@ivar implementations: list of Implementations in this feed
	@ivar name: human-friendly name
	@ivar summary: short textual description
	@ivar description: long textual description
	@ivar stability_policy: user's configured policy.
	Implementations at this level or higher are preferred.
	Lower levels are used only if there is no other choice.
	@ivar last_modified: timestamp on signature
	@ivar last_checked: time feed was last successfully downloaded and updated
	@ivar last_check_attempt: time we last tried to check for updates (in the background)
	@ivar main: deprecated
	@ivar feeds: list of feeds for this interface
	@type feeds: [L{Feed}]
	@ivar feed_for: interfaces for which this could be a feed
	@ivar metadata: extra elements we didn't understand
	"""
	__slots__ = ['uri', 'implementations', 'name', 'description', 'summary',
		     'stability_policy', 'last_modified', 'last_checked',
		     'last_check_attempt', 'main', 'feeds', 'feed_for', 'metadata']


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
		self.last_checked = None
		self.last_check_attempt = None
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
			if id.startswith('package:'):
				impl = DistributionImplementation(self, id)
			else:
				impl = ZeroInstallImplementation(self, id)
			self.implementations[id] = impl
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
	"""Convert each %20 to a space, etc.
	@rtype: str"""
	uri = uri.replace('#', '/')
	if '%' not in uri: return uri
	return re.sub('%[0-9a-fA-F][0-9a-fA-F]',
		lambda match: chr(int(match.group(0)[1:], 16)),
		uri).decode('utf-8')

def escape(uri):
	"""Convert each space to %20, etc
	@rtype: str"""
	return re.sub('[^-_.a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8'))

def _pretty_escape(uri):
	"""Convert each space to %20, etc
	: is preserved and / becomes #. This makes for nicer strings,
	and may replace L{escape} everywhere in future.
	@rtype: str"""
	return re.sub('[^-_.a-zA-Z0-9:/]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8')).replace('/', '#')

def canonical_iface_uri(uri):
	"""If uri is a relative path, convert to an absolute one.
	Otherwise, return it unmodified.
	@rtype: str
	@raise SafeException: if uri isn't valid
	"""
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

_version_mod_to_value = {
	'pre': -2,
	'rc': -1,
	'': 0,
	'post': 1,
}

# Reverse mapping
_version_value_to_mod = {}
for x in _version_mod_to_value: _version_value_to_mod[_version_mod_to_value[x]] = x
del x

_version_re = re.compile('-([a-z]*)')

def parse_version(version_string):
	"""Convert a version string to an internal representation.
	The parsed format can be compared quickly using the standard Python functions.
	 - Version := DottedList ("-" Mod DottedList?)*
	 - DottedList := (Integer ("." Integer)*)
	@rtype: tuple (opaque)
	@raise SafeException: if the string isn't a valid version
	@since: 0.24 (moved from L{reader}, from where it is still available):"""
	if version_string is None: return None
	parts = _version_re.split(version_string)
	if parts[-1] == '':
		del parts[-1]	# Ends with a modifier
	else:
		parts.append('')
	if not parts:
		raise SafeException("Empty version string!")
	l = len(parts)
	try:
		for x in range(0, l, 2):
			part = parts[x]
			if part:
				parts[x] = map(int, parts[x].split('.'))
			else:
				parts[x] = []	# (because ''.split('.') == [''], not [])
		for x in range(1, l, 2):
			parts[x] = _version_mod_to_value[parts[x]]
		return parts
	except ValueError, ex:
		raise SafeException("Invalid version format in '%s': %s" % (version_string, ex))
	except KeyError, ex:
		raise SafeException("Invalid version modifier in '%s': %s" % (version_string, ex))

def format_version(version):
	"""Format a parsed version for display. Undoes the effect of L{parse_version}.
	@see: L{Implementation.get_version}
	@rtype: str
	@since: 0.24"""
	version = version[:]
	l = len(version)
	for x in range(0, l, 2):
		version[x] = '.'.join(map(str, version[x]))
	for x in range(1, l, 2):
		version[x] = '-' + _version_value_to_mod[version[x]]
	if version[-1] == '-': del version[-1]
	return ''.join(version)

