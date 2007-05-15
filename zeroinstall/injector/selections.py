"""
Load and save a set of chosen implementations.
@since: 0.27
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

from zeroinstall.injector import reader
from zeroinstall.injector.policy import Policy
from zeroinstall.injector.model import EnvironmentBinding, InterfaceDependency
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.qdom import Element

class Selection(object):
	"""A single selected implementation in a L{Selections} set."""
	__slots__ = ['interface', 'id', 'version', 'feed', 'dependencies', 'main']

	def __init__(self, interface, id, version, feed, main, dependencies):
		assert interface
		assert id
		assert version
		assert feed
		self.interface = interface
		self.id = id
		self.version = version
		self.feed = feed
		self.main = main
		self.dependencies = dependencies

	def __repr__(self):
		return self.id

class Selections(object):
	__slots__ = ['interface', 'selections']

	def __init__(self, source):
		self.selections = {}
		if isinstance(source, Policy):
			self._init_from_policy(source)
		elif isinstance(source, Element):
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

			self.selections[needed_iface.uri] = Selection(needed_iface.uri, impl.id,
							 impl.get_version(), impl.interface.uri,
							 impl.main,
							 impl.dependencies.values())

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

			bindings = []
			for dep_elem in selection.childNodes:
				if dep_elem.uri != XMLNS_IFACE:
					continue
				if dep_elem.name != 'requires':
					continue
				dep = reader._process_depends(dep_elem)
				bindings.append(dep)

			iface_uri = selection.getAttribute('interface')
			s = Selection(iface_uri,
				      selection.getAttribute('id'),
				      selection.getAttribute('version'),
				      selection.getAttribute('from-feed') or iface_uri,
				      selection.getAttribute('main'),
				      bindings)
			self.selections[iface_uri] = s
	
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

		for selection in self.selections.values():
			selection_elem = doc.createElementNS(XMLNS_IFACE, 'selection')
			selection_elem.setAttributeNS(None, 'interface', selection.interface)
			root.appendChild(selection_elem)

			selection_elem.setAttributeNS(None, 'id', selection.id)
			selection_elem.setAttributeNS(None, 'version', selection.version)
			if selection.main:
				selection_elem.setAttributeNS(None, 'main', selection.main)
			if selection.interface != selection.feed:
				selection_elem.setAttributeNS(None, 'from-feed', selection.feed)

			for dep in selection.dependencies:
				dep_elem = doc.createElementNS(XMLNS_IFACE, 'requires')
				dep_elem.setAttributeNS(None, 'interface', dep.interface)
				selection_elem.appendChild(dep_elem)

				for m in dep.metadata:
					parts = m.split(' ', 1)
					if len(parts) == 1:
						ns = None
						localName = parts[0]
					else:
						ns, localName = parts
					if not ns: ns = None
					dep_elem.setAttributeNS(ns, localName, dep.metadata[m])

				for b in dep.bindings:
					dep_elem.appendChild(b._toxml(doc))

		return doc
	
	def __repr__(self):
		return "Selections for " + self.interface
