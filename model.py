"""In-memory representation of the dependency graph."""

import os

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

buggy = Stability(0, 'buggy', 'Known to have serious bugs')
developer = Stability(10, 'developer', 'Work-in-progress - bugs likely')
testing = Stability(20, 'testing', 'Stability unknown - please test!')
stable = Stability(30, 'stable', 'Tested - no serious problems found')

print stability_levels

class Restriction(object):
	"""A Restriction limits the allowed implementations of an Interface."""

class Binding(object):
	"""Information about how the choice of a Dependency is made known
	to the application being run."""
	__slots__ = ['environ', 'insert']

class Dependency(object):
	"""A Dependency indicates that an Implementation requires some additional
	code to function, specified by another Interface."""
	__slots__ = ['interface', 'restrictions', 'bindings']

	def __init__(self, interface):
		assert isinstance(interface, (str, unicode))
		self.interface = interface
		self.restrictions = []
		self.bindings = []
	
	def get_interface(self):
		return get_interface(self.interface)

class Implementation(object):
	"""An Implementation is a package which implements an Interface."""
	__slots__ = ['path', 'arch', 'stability', 'version', 'size', 'dependencies']

	def __init__(self, version, size, path):
		assert path
		self.path = path
		self.stability = testing
		self.size = size
		self.version = map(int, version.split('.'))
		self.dependencies = {}	# URI -> Dependency
	
	def may_set_stability(self, stability):
		assert isinstance(stability, Stability)

		# Possible transitions:
		# * -> buggy
		# testing -> *
		# developer -> *

		if stability == buggy:
			self.stability = stability
		elif self.stability in (testing, developer):
			self.stability = stability
	
	def get_stability(self):
		return self.stability
	
	def get_cached(self):
		return os.path.exists(self.path)
	
	def get_version(self):
		return '.'.join(map(str, self.version))
	
	def __str__(self):
		return self.path

	def __cmp__(self, other):
		return cmp(other.version, self.version)
	
class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'implementations', 'name', 'uptodate', 'description', 'summary',
		     'stability_policy']
	
	# stability_policy:
	# Implementations at this level or higher are preferred.
	# Lower levels are used only if there is no other choice.

	def __init__(self, uri):
		assert uri
		self.uri = uri
		self.implementations = {}	# Path -> Implementation
		self.name = None
		self.uptodate = False
		self.set_stability_policy(stable)
	
	def get_name(self):
		return self.name or '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri
	
	def get_impl(self, path, version, size):
		if path not in self.implementations:
			self.implementations[path] = Implementation(version, size, path)
		return self.implementations[path]
	
	def set_stability_policy(self, new):
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new
	
	def changed(self):
		for w in self.watchers(): w(self)

_interfaces = {}	# URI -> Interface

def get_interface(uri):
	if uri not in _interfaces:
		_interfaces[uri] = Interface(uri)
	return _interfaces[uri]
