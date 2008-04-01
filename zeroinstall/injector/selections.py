"""
Load and save a set of chosen implementations.
@since: 0.27
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

from zeroinstall.injector.policy import Policy
from zeroinstall.injector.model import EnvironmentBinding, InterfaceDependency, process_binding, process_depends, binding_names
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.qdom import Element

class Selection(object):
	"""A single selected implementation in a L{Selections} set.
	@ivar dependencies: list of dependencies
	@type dependencies: [L{model.Dependency}]
	@ivar attrs: XML attributes map (name is in the format "{namespace} {localName}")
	@type attrs: {str: str}
	@ivar version: the implementation's version number
	@type version: str"""
	__slots__ = ['bindings', 'dependencies', 'attrs']

	def __init__(self, dependencies, bindings = None, attrs = None):
		if bindings is None: bindings = []
		self.dependencies = dependencies
		self.bindings = bindings
		self.attrs = attrs

		assert self.interface
		assert self.id
		assert self.version
		assert self.feed

	interface = property(lambda self: self.attrs['interface'])
	id = property(lambda self: self.attrs['id'])
	version = property(lambda self: self.attrs['version'])
	feed = property(lambda self: self.attrs.get('from-feed', self.interface))
	main = property(lambda self: self.attrs.get('main', None))

	def __repr__(self):
		return self.id

class Selections(object):
	"""
	A selected set of components which will make up a complete program.
	@ivar interface: the interface of the program
	@type interface: str
	@ivar selections: the selected implementations
	@type selections: {str: L{Selection}}
	"""
	__slots__ = ['interface', 'selections']

	def __init__(self, source):
		if isinstance(source, dict):
			self.selections = source
		elif isinstance(source, Policy):
			self.selections = {}
			self._init_from_policy(source)
		elif isinstance(source, Element):
			self.selections = {}
			self._init_from_qdom(source)
		else:
			raise Exception("Source not a Policy or qdom.Element!")

	def _init_from_policy(self, policy):
		"""Set the selections from a policy.
		@param policy: the policy giving the selected implementations."""
		self.interface = policy.root

		for needed_iface in policy.implementation:
			impl = policy.implementation[needed_iface]
			assert impl

			attrs = {'id': impl.id,
				'version': impl.get_version(),
				'interface': needed_iface.uri,
				'from-feed': impl.feed.url}
			if impl.main:
				attrs['main'] = impl.main

			self.selections[needed_iface.uri] = Selection(impl.requires, impl.bindings, attrs)

	def _init_from_qdom(self, root):
		"""Parse and load a selections document.
		@param root: a saved set of selections."""
		self.interface = root.getAttribute('interface')
		assert self.interface

		for selection in root.childNodes:
			if selection.uri != XMLNS_IFACE:
				continue
			if selection.name != 'selection':
				continue

			requires = []
			bindings = []
			for dep_elem in selection.childNodes:
				if dep_elem.uri != XMLNS_IFACE:
					continue
				if dep_elem.name in binding_names:
					bindings.append(process_binding(dep_elem))
				elif dep_elem.name == 'requires':
					dep = process_depends(dep_elem)
					requires.append(dep)

			s = Selection(requires, bindings, selection.attrs)
			self.selections[selection.attrs['interface']] = s
	
	def toDOM(self):
		"""Create a DOM document for the selected implementations.
		The document gives the URI of the root, plus each selected implementation.
		For each selected implementation, we record the ID, the version, the URI and
		(if different) the feed URL. We also record all the bindings needed.
		@return: a new DOM Document"""
		from xml.dom import minidom, XMLNS_NAMESPACE

		assert self.interface

		impl = minidom.getDOMImplementation()

		doc = impl.createDocument(XMLNS_IFACE, "selections", None)

		root = doc.documentElement
		root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns', XMLNS_IFACE)

		root.setAttributeNS(None, 'interface', self.interface)

		def ensure_prefix(prefixes, ns):
			prefix = prefixes.get(ns, None)
			if prefix:
				return prefix
			prefix = 'ns%d' % len(prefixes)
			prefixes[ns] = prefix
			return prefix

		prefixes = {}

		for iface, selection in sorted(self.selections.items()):
			selection_elem = doc.createElementNS(XMLNS_IFACE, 'selection')
			selection_elem.setAttributeNS(None, 'interface', selection.interface)
			root.appendChild(selection_elem)

			for name, value in selection.attrs.iteritems():
				if ' ' in name:
					ns, localName = name.split(' ', 1)
					selection_elem.setAttributeNS(ns, ensure_prefix(prefixes, ns) + ':' + localName, value)
				elif name != 'from-feed':
					selection_elem.setAttributeNS(None, name, value)
				elif value != selection.attrs['interface']:
					# Don't bother writing from-feed attr if it's the same as the interface
					selection_elem.setAttributeNS(None, name, value)

			for b in selection.bindings:
				selection_elem.appendChild(b._toxml(doc))

			for dep in selection.dependencies:
				dep_elem = doc.createElementNS(XMLNS_IFACE, 'requires')
				dep_elem.setAttributeNS(None, 'interface', dep.interface)
				selection_elem.appendChild(dep_elem)

				for m in dep.metadata:
					parts = m.split(' ', 1)
					if len(parts) == 1:
						ns = None
						localName = parts[0]
						dep_elem.setAttributeNS(None, localName, dep.metadata[m])
					else:
						ns, localName = parts
						dep_elem.setAttributeNS(ns, ensure_prefix(prefixes, ns) + ':' + localName, dep.metadata[m])

				for b in dep.bindings:
					dep_elem.appendChild(b._toxml(doc))

		for ns, prefix in prefixes.items():
			root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns:' + prefix, ns)

		return doc
	
	def __repr__(self):
		return "Selections for " + self.interface
