"""In-memory representation of the dependency graph."""

import os

network_offline = 'off-line'
network_minimal = 'minimal'
network_full = 'full'
network_levels = (network_offline, network_minimal, network_full)

stability_levels = {}	# Name -> Stability

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

class Binding(object):
	"""Information about how the choice of a Dependency is made known
	to the application being run."""

class EnvironmentBinding(Binding):
	__slots__ = ['name', 'insert']

	def __init__(self, name, insert):
		self.name = name
		self.insert = insert
	
	def __str__(self):
		return "<environ %s += %s>" % (self.name, self.insert)

class Dependency(object):
	"""A Dependency indicates that an Implementation requires some additional
	code to function, specified by another Interface."""
	__slots__ = ['interface', 'restrictions', 'bindings']

	def __init__(self, interface):
		assert isinstance(interface, (str, unicode))
		self.interface = interface
		self.restrictions = []
		self.bindings = []
	
	def __str__(self):
		return "<Dependency on %s; bindings: %d>" % (self.interface, len(self.bindings))

class Implementation(object):
	"""An Implementation is a package which implements an Interface."""
	__slots__ = ['arch', 'upstream_stability', 'user_stability',
		     'version', 'size', 'dependencies', '_cached',
		     'id']

	def __init__(self, id):
		"""id can be a local path (string starting with /) or a manifest hash (eg "sha1=XXX")"""
		assert id
		self.id = id
		self.size = None
		self.version = None
		self.user_stability = None
		self.upstream_stability = None
		self.arch = None
		self._cached = None
		self.dependencies = {}	# URI -> Dependency
	
	def get_stability(self):
		return self.user_stability or self.upstream_stability or testing
	
	def get_version(self):
		return '.'.join(map(str, self.version))
	
	def __str__(self):
		return self.id

	def __cmp__(self, other):
		return cmp(other.version, self.version)
	
class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'implementations', 'name', 'description', 'summary',
		     'stability_policy', 'last_updated', 'last_modified', 'last_checked']
	
	# stability_policy:
	# Implementations at this level or higher are preferred.
	# Lower levels are used only if there is no other choice.

	# last_updated:
	# The time we last updated the cached information (the time is stored
	# in the cache). None means we haven't even read the cache yet.

	def __init__(self, uri):
		assert uri
		self.uri = uri
		self.reset()

	def reset(self):
		self.implementations = {}	# Path -> Implementation
		self.name = None
		self.last_updated = None
		self.summary = None
		self.description = None
		self.stability_policy = None
		self.last_modified = None
		self.last_checked = None
	
	def get_name(self):
		return self.name or '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri
	
	def get_impl(self, id):
		if id not in self.implementations:
			self.implementations[id] = Implementation(id)
		return self.implementations[id]
	
	def set_stability_policy(self, new):
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new

def escape(uri):
	"Convert each space to %20, etc"
	import re
	return re.sub('[^-_.a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8'))

class SafeException(Exception):
	pass

try:
	_cache = os.readlink('/uri/0install/.lazyfs-cache')
except:
	_cache = None
def cache_for(path):
	prefix = '/uri/0install/'
	if path.startswith(prefix) and _cache:
		return os.path.join(_cache, path[len(prefix):])
	return path
