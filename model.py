"""In-memory representation of the dependency graph."""

import os

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
		assert isinstance(interface, Interface)
		self.interface = interface
		self.restrictions = []
		self.bindings = []

class Implementation(object):
	"""An Implementation is a package which implements an Interface."""
	__slots__ = ['path', 'arch', 'stability', 'version', 'size']

	def __init__(self, version, size, path):
		assert path
		self.path = path
		self.stability = 'testing'
		self.size = size
		self.version = map(int, version.split('.'))
	
	def may_set_stability(self, stability):
		assert stability in ('testing', 'stable', 'buggy')

		# Possible transitions:
		# * -> buggy
		# testing -> stable

		if stability == 'buggy':
			self.stability = stability
		elif self.stability == 'testing':
			self.stability = stability
	
	def get_stability(self):
		return self.stability
	
	def get_cached(self):
		return os.path.exists(self.path)
	
	def __str__(self):
		return self.path

	def __cmp__(self, other):
		return cmp(other.version, self.version)
	
class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'implementations', 'name', 'dependencies', 'uptodate', 'description', 'summary']

	def __init__(self, uri):
		assert uri
		self.uri = uri
		self.implementations = {}	# Path -> Implementation
		self.name = None
		self.dependencies = []
		self.uptodate = False
	
	def get_name(self):
		return self.name or '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri
	
	def get_impl(self, path, version, size):
		if path not in self.implementations:
			self.implementations[path] = Implementation(version, size, path)
		return self.implementations[path]

_interfaces = {}	# URI -> Interface

def get_interface(uri):
	if uri not in _interfaces:
		_interfaces[uri] = Interface(uri)
	return _interfaces[uri]
