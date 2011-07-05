"""
Load and save a set of chosen implementations.
@since: 0.27
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from zeroinstall import _
from zeroinstall.injector import model
from zeroinstall.injector.policy import Policy, get_deprecated_singleton_config
from zeroinstall.injector.model import process_binding, process_depends, binding_names, Command
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.qdom import Element, Prefixes
from zeroinstall.support import tasks

class Selection(object):
	"""A single selected implementation in a L{Selections} set.
	@ivar dependencies: list of dependencies
	@type dependencies: [L{model.Dependency}]
	@ivar attrs: XML attributes map (name is in the format "{namespace} {localName}")
	@type attrs: {str: str}
	@ivar version: the implementation's version number
	@type version: str"""

	interface = property(lambda self: self.attrs['interface'])
	id = property(lambda self: self.attrs['id'])
	version = property(lambda self: self.attrs['version'])
	feed = property(lambda self: self.attrs.get('from-feed', self.interface))
	main = property(lambda self: self.attrs.get('main', None))

	@property
	def local_path(self):
		local_path = self.attrs.get('local-path', None)
		if local_path:
			return local_path
		if self.id.startswith('/'):
			return self.id
		return None

	def __repr__(self):
		return self.id

	def is_available(self, stores):
		"""Is this implementation available locally?
		(a local implementation or a cached ZeroInstallImplementation)
		@rtype: bool
		@since: 0.53"""
		path = self.local_path
		if path is not None:
			return os.path.exists(path)
		path = stores.lookup_maybe(self.digests)
		return path is not None

class ImplSelection(Selection):
	"""A Selection created from an Implementation"""

	__slots__ = ['impl', 'dependencies', 'attrs', '_used_commands']

	def __init__(self, iface_uri, impl, dependencies):
		assert impl
		self.impl = impl
		self.dependencies = dependencies
		self._used_commands = set()

		attrs = impl.metadata.copy()
		attrs['id'] = impl.id
		attrs['version'] = impl.get_version()
		attrs['interface'] = iface_uri
		attrs['from-feed'] = impl.feed.url
		if impl.local_path:
			attrs['local-path'] = impl.local_path
		self.attrs = attrs

	@property
	def bindings(self): return self.impl.bindings

	@property
	def digests(self): return self.impl.digests

	def get_command(self, name):
		assert name in self._used_commands
		return self.impl.commands[name]

	def get_commands(self):
		commands = {}
		for c in self._used_commands:
			commands[c] = self.impl.commands[c]
		return commands

class XMLSelection(Selection):
	"""A Selection created by reading an XML selections document.
	@ivar digests: a list of manifest digests
	@type digests: [str]
	"""
	__slots__ = ['bindings', 'dependencies', 'attrs', 'digests', 'commands']

	def __init__(self, dependencies, bindings = None, attrs = None, digests = None, commands = None):
		if bindings is None: bindings = []
		if digests is None: digests = []
		self.dependencies = dependencies
		self.bindings = bindings
		self.attrs = attrs
		self.digests = digests
		self.commands = commands

		assert self.interface
		assert self.id
		assert self.version
		assert self.feed

	def get_command(self, name):
		return self.commands[name]

	def get_commands(self):
		return self.commands

class Selections(object):
	"""
	A selected set of components which will make up a complete program.
	@ivar interface: the interface of the program
	@type interface: str
	@ivar command: the command to run on 'interface'
	@type command: str
	@ivar selections: the selected implementations
	@type selections: {str: L{Selection}}
	"""
	__slots__ = ['interface', 'selections', 'command']

	def __init__(self, source):
		"""Constructor.
		@param source: a map of implementations, policy or selections document
		@type source: L{Element}
		"""
		self.selections = {}
		self.command = None

		if source is None:
			# (Solver will fill everything in)
			pass
		elif isinstance(source, Policy):
			import warnings
			warnings.warn("Use policy.solver.selections instead", DeprecationWarning, 2)
			self._init_from_policy(source)
		elif isinstance(source, Element):
			self._init_from_qdom(source)
		else:
			raise Exception(_("Source not a qdom.Element!"))

	def _init_from_policy(self, policy):
		"""Set the selections from a policy.
		@deprecated: use Solver.selections instead
		@param policy: the policy giving the selected implementations."""
		self.interface = policy.root
		self.selections = policy.solver.selections.selections
		self.commands = policy.solver.selections.commands

	def _init_from_qdom(self, root):
		"""Parse and load a selections document.
		@param root: a saved set of selections."""
		self.interface = root.getAttribute('interface')
		self.command = root.getAttribute('command')
		assert self.interface
		old_commands = []

		for selection in root.childNodes:
			if selection.uri != XMLNS_IFACE:
				continue
			if selection.name != 'selection':
				if selection.name == 'command':
					old_commands.append(Command(selection, None))
				continue

			requires = []
			bindings = []
			digests = []
			commands = {}
			for elem in selection.childNodes:
				if elem.uri != XMLNS_IFACE:
					continue
				if elem.name in binding_names:
					bindings.append(process_binding(elem))
				elif elem.name == 'requires':
					dep = process_depends(elem, None)
					requires.append(dep)
				elif elem.name == 'manifest-digest':
					for aname, avalue in elem.attrs.iteritems():
						digests.append('%s=%s' % (aname, avalue))
				elif elem.name == 'command':
					commands[elem.getAttribute('name')] = Command(elem, None)

			# For backwards compatibility, allow getting the digest from the ID
			sel_id = selection.attrs['id']
			local_path = selection.attrs.get("local-path", None)
			if (not digests and not local_path) and '=' in sel_id:
				alg = sel_id.split('=', 1)[0]
				if alg in ('sha1', 'sha1new', 'sha256'):
					digests.append(sel_id)

			iface_uri = selection.attrs['interface']

			s = XMLSelection(requires, bindings, selection.attrs, digests, commands)
			self.selections[iface_uri] = s

		if self.command is None:
			# Old style selections document
			if old_commands:
				# 0launch 0.52 to 1.1
				self.command = 'run'
				iface = self.interface
				last_command = None

				for command in old_commands:
					command.qdom.attrs['name'] = 'run'
					self.selections[iface].commands['run'] = command
					runner = command.get_runner()
					if runner:
						iface = runner.interface
					else:
						iface = None
			else:
				# 0launch < 0.51
				root_sel = self.selections[self.interface]
				main = root_sel.attrs.get('main', None)
				if main is not None:
					root_sel.commands['run'] = Command(Element(XMLNS_IFACE, 'command', {'path': main}), None)
					self.command = 'run'

		elif self.command == '':
			# New style, but no command requested
			self.command = None
			assert not old_commands, "<command> list in new-style selections document!"

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

		root.setAttributeNS(None, 'command', self.command or "")

		prefixes = Prefixes(XMLNS_IFACE)

		for iface, selection in sorted(self.selections.items()):
			selection_elem = doc.createElementNS(XMLNS_IFACE, 'selection')
			selection_elem.setAttributeNS(None, 'interface', selection.interface)
			root.appendChild(selection_elem)

			for name, value in selection.attrs.iteritems():
				if ' ' in name:
					ns, localName = name.split(' ', 1)
					prefixes.setAttributeNS(selection_elem, ns, localName, value)
				elif name == 'stability':
					pass
				elif name == 'from-feed':
					# Don't bother writing from-feed attr if it's the same as the interface
					if value != selection.attrs['interface']:
						selection_elem.setAttributeNS(None, name, value)
				elif name not in ('main', 'self-test'):	# (replaced by <command>)
					selection_elem.setAttributeNS(None, name, value)

			if selection.digests:
				manifest_digest = doc.createElementNS(XMLNS_IFACE, 'manifest-digest')
				for digest in selection.digests:
					aname, avalue = digest.split('=', 1)
					assert ':' not in aname
					manifest_digest.setAttribute(aname, avalue)
				selection_elem.appendChild(manifest_digest)

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
						prefixes.setAttributeNS(dep_elem, ns, localName, dep.metadata[m])

				for b in dep.bindings:
					dep_elem.appendChild(b._toxml(doc))

			for command in selection.get_commands().values():
				selection_elem.appendChild(command._toxml(doc, prefixes))

		for ns, prefix in prefixes.prefixes.items():
			root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns:' + prefix, ns)

		return doc
	
	def __repr__(self):
		return "Selections for " + self.interface

	def download_missing(self, config, _old = None):
		"""Check all selected implementations are available.
		Download any that are not present.
		Note: package implementations (distribution packages) are ignored.
		@param config: used to get iface_cache, stores and fetcher
		@return: a L{tasks.Blocker} or None"""
		from zeroinstall.zerostore import NotStored

		if _old:
			config = get_deprecated_singleton_config()

		iface_cache = config.iface_cache
		stores = config.stores

		# Check that every required selection is cached
		needed_downloads = []
		for sel in self.selections.values():
			if (not sel.local_path) and (not sel.id.startswith('package:')):
				try:
					stores.lookup_any(sel.digests)
				except NotStored:
					needed_downloads.append(sel)
		if not needed_downloads:
			return

		if config.network_use == model.network_offline:
			from zeroinstall import NeedDownload
			raise NeedDownload(', '.join([str(x) for x in needed_downloads]))

		@tasks.async
		def download():
			# We're missing some. For each one, get the feed it came from
			# and find the corresponding <implementation> in that. This will
			# tell us where to get it from.
			# Note: we look for an implementation with the same ID. Maybe we
			# should check it has the same digest(s) too?
			needed_impls = []
			for sel in needed_downloads:
				feed_url = sel.attrs.get('from-feed', None) or sel.attrs['interface']
				feed = iface_cache.get_feed(feed_url)
				if feed is None or sel.id not in feed.implementations:
					fetch_feed = config.fetcher.download_and_import_feed(feed_url, iface_cache)
					yield fetch_feed
					tasks.check(fetch_feed)

					feed = iface_cache.get_feed(feed_url)
					assert feed, "Failed to get feed for %s" % feed_url
				impl = feed.implementations[sel.id]
				needed_impls.append(impl)

			fetch_impls = config.fetcher.download_impls(needed_impls, stores)
			yield fetch_impls
			tasks.check(fetch_impls)
		return download()

	# These (deprecated) methods are to make a Selections object look like the old Policy.implementation map...

	def __getitem__(self, key):
		# Deprecated
		if isinstance(key, basestring):
			return self.selections[key]
		sel = self.selections[key.uri]
		return sel and sel.impl

	def iteritems(self):
		# Deprecated
		iface_cache = get_deprecated_singleton_config().iface_cache
		for (uri, sel) in self.selections.iteritems():
			yield (iface_cache.get_interface(uri), sel and sel.impl)

	def values(self):
		# Deprecated
		for (uri, sel) in self.selections.iteritems():
			yield sel and sel.impl

	def __iter__(self):
		# Deprecated
		iface_cache = get_deprecated_singleton_config().iface_cache
		for (uri, sel) in self.selections.iteritems():
			yield iface_cache.get_interface(uri)

	def get(self, iface, if_missing):
		# Deprecated
		sel = self.selections.get(iface.uri, None)
		if sel:
			return sel.impl
		return if_missing

	def copy(self):
		# Deprecated
		s = Selections(None)
		s.interface = self.interface
		s.selections = self.selections.copy()
		return s

	def items(self):
		# Deprecated
		return list(self.iteritems())

	@property
	def commands(self):
		i = self.interface
		c = self.command
		commands = []
		while c is not None:
			sel = self.selections[i]
			command = sel.get_command(c)

			commands.append(command)

			runner = command.get_runner()
			if not runner:
				break

			i = runner.metadata['interface']
			c = runner.qdom.attrs.get('command', 'run')

		return commands
