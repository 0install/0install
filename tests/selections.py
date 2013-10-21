"""
Load and save a set of chosen implementations.
@since: 0.27
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, zerostore
from zeroinstall.injector import model
from zeroinstall.injector.namespaces import XMLNS_IFACE

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
	__slots__ = ['dependencies', 'attrs', 'digests', 'commands']

	def __init__(self, dependencies, attrs = None, digests = None):
		"""@type dependencies: [L{zeroinstall.injector.model.Dependency}]
		@type bindings: [L{zeroinstall.injector.model.Binding}] | None
		@type attrs: {str: str} | None
		@type digests: [str] | None
		@type commands: {str: L{Command}} | None"""
		if digests is None: digests = []
		self.dependencies = dependencies
		self.attrs = attrs
		self.digests = digests

		assert self.interface
		assert self.id
		assert self.version
		assert self.feed

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
		self._init_from_qdom(source)

	def _init_from_qdom(self, root):
		"""Parse and load a selections document.
		@param root: a saved set of selections.
		@type root: L{Element}"""
		self.interface = root.getAttribute('interface')
		self.command = root.getAttribute('command')
		if self.interface is None:
			raise model.SafeException(_("Not a selections document (no 'interface' attribute on root)"))

		for selection in root.childNodes:
			if selection.uri != XMLNS_IFACE:
				continue
			if selection.name != 'selection':
				continue

			requires = []
			digests = []
			for elem in selection.childNodes:
				if elem.uri != XMLNS_IFACE:
					continue
				elif elem.name == 'manifest-digest':
					for aname, avalue in elem.attrs.items():
						digests.append(zerostore.format_algorithm_digest_pair(aname, avalue))

			# For backwards compatibility, allow getting the digest from the ID
			sel_id = selection.attrs['id']
			local_path = selection.attrs.get("local-path", None)
			if (not local_path) and '=' in sel_id:
				alg = sel_id.split('=', 1)[0]
				if alg in ('sha1', 'sha1new', 'sha256'):
					if sel_id not in digests:
						digests.append(sel_id)

			iface_uri = selection.attrs['interface']

			s = XMLSelection(requires, selection.attrs, digests)
			self.selections[iface_uri] = s
