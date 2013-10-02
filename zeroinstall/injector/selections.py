"""
Load and save a set of chosen implementations.
@since: 0.27
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from zeroinstall import _, zerostore
from zeroinstall.injector import model
from zeroinstall.injector.policy import get_deprecated_singleton_config
from zeroinstall.injector.model import process_binding, process_depends, binding_names, Command
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.qdom import Element
from zeroinstall.support import basestring

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
		"""@rtype: str"""
		return self.id

	def is_available(self, stores):
		"""Is this implementation available locally?
		(a local implementation or a cached ZeroInstallImplementation)
		@rtype: bool
		@since: 0.53"""
		path = self.local_path
		if path is not None:
			return os.path.exists(path)
		if not self.digests:
			return False
		path = stores.lookup_maybe(self.digests)
		return path is not None

	def get_path(self, stores, missing_ok = False):
		"""Return the root directory of this implementation.
		For local implementations, this is L{local_path}.
		For cached implementations, this is the directory in the cache.
		@param stores: stores to search
		@type stores: L{zerostore.Stores}
		@param missing_ok: return None for uncached implementations
		@type missing_ok: bool
		@return: the path of the directory
		@rtype: str | None
		@since: 1.8"""
		if self.local_path is not None:
			return self.local_path
		if not self.digests:
			# (for now, we assume this is always an error, even for missing_ok)
			raise model.SafeException("No digests for {feed} {version}".format(feed = self.feed, version = self.version))
		if missing_ok:
			return stores.lookup_maybe(self.digests)
		else:
			return stores.lookup_any(self.digests)

class XMLSelection(Selection):
	"""A Selection created by reading an XML selections document.
	@ivar digests: a list of manifest digests
	@type digests: [str]
	"""
	__slots__ = ['bindings', 'dependencies', 'attrs', 'digests', 'commands']

	def __init__(self, dependencies, bindings = None, attrs = None, digests = None, commands = None):
		"""@type dependencies: [L{zeroinstall.injector.model.Dependency}]
		@type bindings: [L{zeroinstall.injector.model.Binding}] | None
		@type attrs: {str: str} | None
		@type digests: [str] | None
		@type commands: {str: L{Command}} | None"""
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
		"""@type name: str
		@rtype: L{Command}"""
		if name not in self.commands:
			raise model.SafeException("Command '{name}' not present in selections for {iface}".format(name = name, iface = self.interface))
		return self.commands[name]

	def get_commands(self):
		"""@rtype: {str: L{Command}}"""
		return self.commands

	def _get_quick_test_mtime(self):
		attr = self.attrs.get('quick-test-mtime', None)
		if attr is not None:
			attr = int(attr)
		return attr

	quick_test_file = property(lambda self: self.attrs.get('quick-test-file', None))
	quick_test_mtime = property(_get_quick_test_mtime)

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
		@type source: L{Element}"""
		self.selections = {}
		self.command = None

		if source is None:
			# (Solver will fill everything in)
			pass
		elif isinstance(source, Element):
			self._init_from_qdom(source)
		else:
			raise Exception(_("Source not a qdom.Element!"))

	def _init_from_qdom(self, root):
		"""Parse and load a selections document.
		@param root: a saved set of selections.
		@type root: L{Element}"""
		self.interface = root.getAttribute('interface')
		self.command = root.getAttribute('command')
		if self.interface is None:
			raise model.SafeException(_("Not a selections document (no 'interface' attribute on root)"))
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
					for aname, avalue in elem.attrs.items():
						digests.append(zerostore.format_algorithm_digest_pair(aname, avalue))
				elif elem.name == 'command':
					name = elem.getAttribute('name')
					assert name, "Missing name attribute on <command>"
					commands[name] = Command(elem, None)

			# For backwards compatibility, allow getting the digest from the ID
			sel_id = selection.attrs['id']
			local_path = selection.attrs.get("local-path", None)
			if (not local_path) and '=' in sel_id:
				alg = sel_id.split('=', 1)[0]
				if alg in ('sha1', 'sha1new', 'sha256'):
					if sel_id not in digests:
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
					root_sel.commands['run'] = Command(Element(XMLNS_IFACE, 'command', {'path': main, 'name': 'run'}), None)
					self.command = 'run'

		elif self.command == '':
			# New style, but no command requested
			self.command = None
			assert not old_commands, "<command> list in new-style selections document!"

	def __repr__(self):
		return "Selections for " + self.interface

	# These (deprecated) methods are to make a Selections object look like the old Policy.implementation map...

	def __getitem__(self, key):
		# Deprecated
		"""@type key: str
		@rtype: L{ImplSelection}"""
		if isinstance(key, basestring):
			return self.selections[key]
		sel = self.selections[key.uri]
		return sel and sel.impl

	def iteritems(self):
		# Deprecated
		iface_cache = get_deprecated_singleton_config().iface_cache
		for (uri, sel) in self.selections.items():
			yield (iface_cache.get_interface(uri), sel and sel.impl)

	def values(self):
		# Deprecated
		"""@rtype: L{zeroinstall.injector.model.Implementation}"""
		for (uri, sel) in self.selections.items():
			yield sel and sel.impl

	def __iter__(self):
		# Deprecated
		iface_cache = get_deprecated_singleton_config().iface_cache
		for (uri, sel) in self.selections.items():
			yield iface_cache.get_interface(uri)

	def get(self, iface, if_missing):
		# Deprecated
		"""@type iface: L{zeroinstall.injector.model.Interface}
		@rtype: L{zeroinstall.injector.model.Implementation}"""
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
