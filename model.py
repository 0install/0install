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
	__slots__ = ['path', 'arch', 'stability', 'version']

	def __init__(self, version, path):
		assert path
		assert isinstance(version, Version)
		self.path = path
		self.version = version
		self.stability = 'testing'
	
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

class Version(object):
	"""Implementations of an Interface are grouped into numbered Versions"""
	__slots__ = ['number', 'implementations']

	def __init__(self, name):
		self.number = map(int, name.split('.'))
		self.implementations = {}
	
	def __cmp__(self, other):
		return cmp(other.number, self.number)
	
	def __str__(self):
		return '.'.join(map(str, self.number))

	def get_impl(self, path):
		if path not in self.implementations:
			self.implementations[path] = Implementation(self, path)
		return self.implementations[path]

	def get_stability(self):
		"""Returns best stability of all implementations"""
		if not self.implementations:
			return '-'
		have_testing = False
		for x in self.implementations.itervalues():
			if x.stability == 'stable':
				return x.stability
			elif x.stability == 'testing':
				have_testing = True
		if have_testing:
			return 'testing'
		return 'buggy'
	
	def get_cached(self):
		for x in self.implementations.itervalues():
			if x.get_cached():
				return True
		return False

class Interface(object):
	"""An Interface represents some contract of behaviour."""
	__slots__ = ['uri', 'versions', 'name', 'dependencies', 'uptodate', 'description', 'summary']

	def __init__(self, uri):
		assert uri
		self.uri = uri
		self.versions = {}
		self.name = None
		self.dependencies = []
		self.uptodate = False
	
	def get_name(self):
		return self.name or '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri

	def get_version(self, version_name):
		if version_name not in self.versions:
			self.versions[version_name] = Version(version_name)
		return self.versions[version_name]

_interfaces = {}	# URI -> Interface

def get_interface(uri):
	if uri not in _interfaces:
		_interfaces[uri] = Interface(uri)
	return _interfaces[uri]
