#!/usr/bin/env python
import os, sys
from xml.dom import minidom, Node

from namespaces import XMLNS_IFACE

class InterfaceException(Exception):
	path = '<unknown>'

	def __init__(self, msg):
		Exception.__init__(self, msg)
	
	def set_file(self, path):
		self.path = path
	
	def __str__(self):
		return Exception.__str__(self) + " in '%s'" % self.path

def get_singleton_text(parent, ns, localName):
	names = parent.getElementsByTagNameNS(ns, localName)
	if not names:
		raise InterfaceException('No <%s> element in <%s>' % (localName, parent.localName))
	if len(names) > 1:
		raise InterfaceException('Multiple <%s> elements in <%s>' % (localName, parent.localName))
	text = ''
	for x in names[0].childNodes:
		if x.nodeType == Node.TEXT_NODE:
			text += x.data
	return text.strip()

class Implementation:
	interface = None
	path = None
	version = None
	dependancies = None

	def __init__(self, interface, path, version, dependancies):
		assert path
		assert version
		assert interface

		self.interface = interface
		self.path = path
		self.version = map(int, version.split('.'))
		self.dependancies = dependancies
	
	def __cmp__(self, other):
		"""Sorts highest version first."""
		return -cmp(self.version, other.version)
	
	def __repr__(self):
		return "<version %s at %s; %s>" % (self.version, self.path, self.dependancies)
	
	def get_version(self):
		return '.'.join(map(str, self.version))

class Environment:
	name = None
	insert = None

	def __init__(self, element):
		self.name = element.getAttribute('name')
		self.insert = element.getAttribute('insert')
	
	def setup_binding(self, impl):
		extra = os.path.join(impl.path, self.insert)
		if self.name in os.environ:
			os.environ[self.name] = extra + ':' + os.environ[self.name]
		else:
			os.environ[self.name] = extra
		print "%s now %s" % (self.name, os.environ[self.name])

class Depends:
	def __init__(self, element):
		self.interface = element.getAttribute('interface')
		assert self.interface

		envs = element.getElementsByTagNameNS(XMLNS_IFACE, 'environment')
		self.envs = map(Environment, envs)
	
	def __repr__(self):
		return "<dependancy on %s>" % self.interface
	
	def get_interface(self):
		return get_interface(self.interface)
	
	def setup_bindings(self, selection):
		print "Setting up", self
		iface = get_interface(self.interface)
		impl = selection[iface]
		for e in self.envs:
			e.setup_binding(impl)

class Interface:
	doc = None
	path = None
	implementations = None

	def __init__(self, path):
		assert path.startswith('/')

		self.path = path
		self.doc = minidom.parse(path)
		self.implementations = []

		assert self.doc.documentElement.namespaceURI == XMLNS_IFACE
		assert self.doc.documentElement.localName == 'interface'

		def scan(element, path, version, depends):
			depends = depends[:]

			if element.hasAttribute('path'):
				path = os.path.join(path, element.getAttribute('path'))
			if element.hasAttribute('version'):
				version = element.getAttribute('version')

			if element.localName in ('group', 'interface'):
				kids = [x for x in element.childNodes
					if x.nodeType == Node.ELEMENT_NODE]

				for x in kids:
					if x.localName == 'requires':
						depends.append(Depends(x))
				for x in kids:
					scan(x, path, version, depends)
			elif element.localName == 'implementation':
				self.implementations.append(Implementation(self, path, version, depends))
			elif element.localName in ('requires', 'name', 'description'):
				pass	# Handled by parent
			else:
				print "Skipping unknown element", element.localName
		root = self.doc.documentElement
		scan(root, path = None, version = None, depends = [])

		self.implementations.sort()

		self.name = get_singleton_text(root, XMLNS_IFACE, 'name')
		self.description = get_singleton_text(root, XMLNS_IFACE, 'description')
	
	def __str__(self):
		return self.name

	def __repr__(self):
		return "<Interface: %s>" % self.path
	
_cached_interfaces = {}
def get_interface(path):
	if path not in _cached_interfaces:
		try:
			_cached_interfaces[path] = Interface(path)
		except InterfaceException, ex:
			ex.set_file(path)
			raise
	return _cached_interfaces[path]
