"""In-memory representation of interfaces and other data structures.

The objects in this module are used to build a representation of an XML interface
file in memory.

@see: L{reader} constructs these data-structures
@see: U{http://0install.net/interface-spec.html} description of the domain model

@var defaults: Default values for the 'default' attribute for <environment> bindings of
well-known variables.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, re
from logging import info, debug
from zeroinstall import SafeException, version
from zeroinstall.injector.namespaces import XMLNS_IFACE

# Element names for bindings in feed files
binding_names = frozenset(['environment', 'overlay'])

network_offline = 'off-line'
network_minimal = 'minimal'
network_full = 'full'
network_levels = (network_offline, network_minimal, network_full)

stability_levels = {}	# Name -> Stability

defaults = {
	'PATH': '/bin:/usr/bin',
	'XDG_CONFIG_DIRS': '/etc/xdg',
	'XDG_DATA_DIRS': '/usr/local/share:/usr/share',
}

class InvalidInterface(SafeException):
	"""Raised when parsing an invalid feed."""
	def __init__(self, message, ex = None):
		if ex:
			message += "\n\n(exact error: %s)" % ex
		SafeException.__init__(self, message)

def _split_arch(arch):
	"""Split an arch into an (os, machine) tuple. Either or both parts may be None."""
	if not arch:
		return None, None
	elif '-' not in arch:
		raise SafeException("Malformed arch '%s'" % arch)
	else:
		osys, machine = arch.split('-', 1)
		if osys == '*': osys = None
		if machine == '*': machine = None
		return osys, machine

def _join_arch(osys, machine):
	if osys == machine == None: return None
	return "%s-%s" % (osys or '*', machine or '*')
	
class Stability(object):
	"""A stability rating. Each implementation has an upstream stability rating and,
	optionally, a user-set rating."""
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

	def __repr__(self):
		return "<Stability: " + self.description + ">"

def process_binding(e):
	"""Internal"""
	if e.name == 'environment':
		mode = {
			None: EnvironmentBinding.PREPEND,
			'prepend': EnvironmentBinding.PREPEND,
			'append': EnvironmentBinding.APPEND,
			'replace': EnvironmentBinding.REPLACE,
		}[e.getAttribute('mode')]
			
		binding = EnvironmentBinding(e.getAttribute('name'),
					     insert = e.getAttribute('insert'),
					     default = e.getAttribute('default'),
					     mode = mode)
		if not binding.name: raise InvalidInterface("Missing 'name' in binding")
		if binding.insert is None: raise InvalidInterface("Missing 'insert' in binding")
		return binding
	elif e.name == 'overlay':
		return OverlayBinding(e.getAttribute('src'), e.getAttribute('mount-point'))
	else:
		raise Exception("Unknown binding type '%s'" % e.name)

def process_depends(item):
	"""Internal"""
	# Note: also called from selections
	dep_iface = item.getAttribute('interface')
	if not dep_iface:
		raise InvalidInterface("Missing 'interface' on <requires>")
	dependency = InterfaceDependency(dep_iface, metadata = item.attrs)

	for e in item.childNodes:
		if e.uri != XMLNS_IFACE: continue
		if e.name in binding_names:
			dependency.bindings.append(process_binding(e))
		elif e.name == 'version':
			dependency.restrictions.append(
				VersionRangeRestriction(not_before = parse_version(e.getAttribute('not-before')),
						        before = parse_version(e.getAttribute('before'))))
	return dependency


insecure = Stability(0, 'insecure', 'This is a security risk')
buggy = Stability(5, 'buggy', 'Known to have serious bugs')
developer = Stability(10, 'developer', 'Work-in-progress - bugs likely')
testing = Stability(20, 'testing', 'Stability unknown - please test!')
stable = Stability(30, 'stable', 'Tested - no serious problems found')
packaged = Stability(35, 'packaged', 'Supplied by the local package manager')
preferred = Stability(40, 'preferred', 'Best of all - must be set manually')

class Restriction(object):
	"""A Restriction limits the allowed implementations of an Interface."""
	__slots__ = []

	def meets_restriction(self, impl):
		raise NotImplementedError("Abstract")
	
class VersionRangeRestriction(Restriction):
	"""Only versions within the given range are acceptable"""
	__slots__ = ['before', 'not_before']
	def __init__(self, before, not_before):
		self.before = before
		self.not_before = not_before
	
	def meets_restriction(self, impl):
		if self.not_before and impl.version < self.not_before:
			return False
		if self.before and impl.version >= self.before:
			return False
		return True
	
	def __str__(self):
		if self.not_before is not None or self.before is not None:
			range = ''
			if self.not_before is not None:
				range += format_version(self.not_before) + ' <= '
			range += 'version'
			if self.before is not None:
				range += ' < ' + format_version(self.before)
		else:
			range = 'none'
		return "(restriction: %s)" % range

class Binding(object):
	"""Information about how the choice of a Dependency is made known
	to the application being run."""

class EnvironmentBinding(Binding):
	"""Indicate the chosen implementation using an environment variable."""
	__slots__ = ['name', 'insert', 'default', 'mode']

	PREPEND = 'prepend'
	APPEND = 'append'
	REPLACE = 'replace'

	def __init__(self, name, insert, default = None, mode = PREPEND):
		"""mode argument added in version 0.28"""
		self.name = name
		self.insert = insert
		self.default = default
		self.mode = mode
	
	def __str__(self):
		return "<environ %s %s %s>" % (self.name, self.mode, self.insert)

	__repr__ = __str__
	
	def get_value(self, path, old_value):
		"""Calculate the new value of the environment variable after applying this binding.
		@param path: the path to the selected implementation
		@param old_value: the current value of the environment variable
		@return: the new value for the environment variable"""
		extra = os.path.join(path, self.insert)

		if self.mode == EnvironmentBinding.REPLACE:
			return extra

		if old_value is None:
			old_value = self.default or defaults.get(self.name, None)
		if old_value is None:
			return extra
		if self.mode == EnvironmentBinding.PREPEND:
			return extra + ':' + old_value
		else:
			return old_value + ':' + extra

	def _toxml(self, doc):
		"""Create a DOM element for this binding.
		@param doc: document to use to create the element
		@return: the new element
		"""
		env_elem = doc.createElementNS(XMLNS_IFACE, 'environment')
		env_elem.setAttributeNS(None, 'name', self.name)
		env_elem.setAttributeNS(None, 'insert', self.insert)
		if self.default:
			env_elem.setAttributeNS(None, 'default', self.default)
		return env_elem

class OverlayBinding(Binding):
	"""Make the chosen implementation available by overlaying it onto another part of the file-system.
	This is to support legacy programs which use hard-coded paths."""
	__slots__ = ['src', 'mount_point']

	def __init__(self, src, mount_point):
		self.src = src
		self.mount_point = mount_point

	def __str__(self):
		return "<overlay %s on %s>" % (self.src or '.', self.mount_point or '/')

	__repr__ = __str__

	def _toxml(self, doc):
		"""Create a DOM element for this binding.
		@param doc: document to use to create the element
		@return: the new element
		"""
		env_elem = doc.createElementNS(XMLNS_IFACE, 'overlay')
		if self.src is not None:
			env_elem.setAttributeNS(None, 'src', self.src)
		if self.mount_point is not None:
			env_elem.setAttributeNS(None, 'mount-point', self.mount_point)
		return env_elem

class Feed(object):
	"""An interface's feeds are other interfaces whose implementations can also be
	used as implementations of this interface."""
	__slots__ = ['uri', 'os', 'machine', 'user_override', 'langs']
	def __init__(self, uri, arch, user_override, langs = None):
		self.uri = uri
		# This indicates whether the feed comes from the user's overrides
		# file. If true, writer.py will write it when saving.
		self.user_override = user_override
		self.os, self.machine = _split_arch(arch)
		self.langs = langs
	
	def __str__(self):
		return "<Feed from %s>" % self.uri
	__repr__ = __str__

	arch = property(lambda self: _join_arch(self.os, self.machine))

class Dependency(object):
	"""A Dependency indicates that an Implementation requires some additional
	code to function. This is an abstract base class.
	@ivar metadata: any extra attributes from the XML element
	@type metadata: {str: str}
	"""
	__slots__ = ['metadata']

	def __init__(self, metadata):
		if metadata is None:
			metadata = {}
		else:
			assert not isinstance(metadata, basestring)	# Use InterfaceDependency instead!
		self.metadata = metadata

class InterfaceDependency(Dependency):
	"""A Dependency on a Zero Install interface.
	@ivar interface: the interface required by this dependency
	@type interface: str
	@ivar restrictions: a list of constraints on acceptable implementations
	@type restrictions: [L{Restriction}]
	@ivar bindings: how to make the choice of implementation known
	@type bindings: [L{Binding}]
	@since: 0.28
	"""
	__slots__ = ['interface', 'restrictions', 'bindings', 'metadata']

	def __init__(self, interface, restrictions = None, metadata = None):
		Dependency.__init__(self, metadata)
		assert isinstance(interface, (str, unicode))
		assert interface
		self.interface = interface
		if restrictions is None:
			self.restrictions = []
		else:
			self.restrictions = restrictions
		self.bindings = []
	
	def __str__(self):
		return "<Dependency on %s; bindings: %s%s>" % (self.interface, self.bindings, self.restrictions)

class RetrievalMethod(object):
	"""A RetrievalMethod provides a way to fetch an implementation."""
	__slots__ = []

class DownloadSource(RetrievalMethod):
	"""A DownloadSource provides a way to fetch an implementation."""
	__slots__ = ['implementation', 'url', 'size', 'extract', 'start_offset', 'type']

	def __init__(self, implementation, url, size, extract, start_offset = 0, type = None):
		self.implementation = implementation
		self.url = url
		self.size = size
		self.extract = extract
		self.start_offset = start_offset
		self.type = type		# MIME type - see unpack.py

class Recipe(RetrievalMethod):
	"""Get an implementation by following a series of steps.
	@ivar size: the combined download sizes from all the steps
	@type size: int
	@ivar steps: the sequence of steps which must be performed
	@type steps: [L{RetrievalMethod}]"""
	__slots__ = ['steps']

	def __init__(self):
		self.steps = []
	
	size = property(lambda self: sum([x.size for x in self.steps]))

class Implementation(object):
	"""An Implementation is a package which implements an Interface.
	@ivar download_sources: list of methods of getting this implementation
	@type download_sources: [L{RetrievalMethod}]
	@ivar feed: the feed owning this implementation (since 0.32)
	@type feed: [L{ZeroInstallFeed}]
	@ivar bindings: how to tell this component where it itself is located (since 0.31)
	@type bindings: [Binding]
	@ivar upstream_stability: the stability reported by the packager
	@type upstream_stability: [insecure | buggy | developer | testing | stable | packaged]
	@ivar user_stability: the stability as set by the user
	@type upstream_stability: [insecure | buggy | developer | testing | stable | packaged | preferred]
	@ivar langs: natural languages supported by this package
	@ivar requires: interfaces this package depends on
	@ivar main: the default file to execute when running as a program
	@ivar metadata: extra metadata from the feed
	@type metadata: {"[URI ]localName": str}
	@ivar id: a unique identifier for this Implementation
	@ivar version: a parsed version number
	@ivar released: release date
	"""

	# Note: user_stability shouldn't really be here

	__slots__ = ['upstream_stability', 'user_stability', 'langs',
		     'requires', 'main', 'metadata', 'download_sources',
		     'id', 'feed', 'version', 'released', 'bindings']

	def __init__(self, feed, id):
		assert id
		self.feed = feed
		self.id = id
		self.main = None
		self.user_stability = None
		self.upstream_stability = None
		self.metadata = {}	# [URI + " "] + localName -> value
		self.requires = []
		self.version = None
		self.released = None
		self.download_sources = []
		self.langs = None
		self.bindings = []

	def get_stability(self):
		return self.user_stability or self.upstream_stability or testing
	
	def __str__(self):
		return self.id

	def __repr__(self):
		return "v%s (%s)" % (self.get_version(), self.id)

	def __cmp__(self, other):
		"""Newer versions come first"""
		return cmp(other.version, self.version)

	def get_version(self):
		"""Return the version as a string.
		@see: L{format_version}
		"""
		return format_version(self.version)

	arch = property(lambda self: _join_arch(self.os, self.machine))

	os = machine = None

class DistributionImplementation(Implementation):
	"""An implementation provided by the distribution. Information such as the version
	comes from the package manager.
	@since: 0.28"""
	__slots__ = ['installed']

	def __init__(self, feed, id):
		assert id.startswith('package:')
		Implementation.__init__(self, feed, id)
		self.installed = True
	
class ZeroInstallImplementation(Implementation):
	"""An implementation where all the information comes from Zero Install.
	@since: 0.28"""
	__slots__ = ['os', 'machine', 'size']

	def __init__(self, feed, id):
		"""id can be a local path (string starting with /) or a manifest hash (eg "sha1=XXX")"""
		Implementation.__init__(self, feed, id)
		self.size = None
		self.os = None
		self.machine = None

	# Deprecated
	dependencies = property(lambda self: dict([(x.interface, x) for x in self.requires
						   if isinstance(x, InterfaceDependency)]))
	
	def add_download_source(self, url, size, extract, start_offset = 0, type = None):
		"""Add a download source."""
		self.download_sources.append(DownloadSource(self, url, size, extract, start_offset, type))
	
	def set_arch(self, arch):
		self.os, self.machine = _split_arch(arch)
	arch = property(lambda self: _join_arch(self.os, self.machine), set_arch)
	
class Interface(object):
	"""An Interface represents some contract of behaviour.
	@ivar uri: the URI for this interface.
	@ivar stability_policy: user's configured policy.
	Implementations at this level or higher are preferred.
	Lower levels are used only if there is no other choice.
	"""
	__slots__ = ['uri', 'stability_policy', '_main_feed', 'extra_feeds']

	implementations = property(lambda self: self._main_feed.implementations)
	name = property(lambda self: self._main_feed.name)
	description = property(lambda self: self._main_feed.description)
	summary = property(lambda self: self._main_feed.summary)
	last_modified = property(lambda self: self._main_feed.last_modified)
	feeds = property(lambda self: self.extra_feeds + self._main_feed.feeds)
	metadata = property(lambda self: self._main_feed.metadata)

	last_checked = property(lambda self: self._main_feed.last_checked)

	def __init__(self, uri):
		assert uri
		if uri.startswith('http:') or uri.startswith('/'):
			self.uri = uri
		else:
			raise SafeException("Interface name '%s' doesn't start "
					    "with 'http:'" % uri)
		self.reset()

	def _get_feed_for(self):
		retval = {}
		for key in self._main_feed.feed_for:
			retval[key] = True
		return retval
	feed_for = property(_get_feed_for)	# Deprecated (used by 0publish)

	def reset(self):
		self.extra_feeds = []
		self._main_feed = _dummy_feed
		self.stability_policy = None

	def get_name(self):
		if self._main_feed is not _dummy_feed:
			return self._main_feed.get_name()
		return '(' + os.path.basename(self.uri) + ')'
	
	def __repr__(self):
		return "<Interface %s>" % self.uri
	
	def set_stability_policy(self, new):
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new
	
	def get_feed(self, url):
		for x in self.extra_feeds:
			if x.uri == url:
				return x
		return self._main_feed.get_feed(url)
	
	def get_metadata(self, uri, name):
		return self._main_feed.get_metadata(uri, name)

def _merge_attrs(attrs, item):
	"""Add each attribute of item to a copy of attrs and return the copy.
	@type attrs: {str: str}
	@type item: L{qdom.Element}
	@rtype: {str: str}
	"""
	new = attrs.copy()
	for a in item.attrs:
		new[str(a)] = item.attrs[a]
	return new

def _get_long(elem, attr_name):
	val = elem.getAttribute(attr_name)
	if val is not None:
		try:
			val = long(val)
		except ValueError, ex:
			raise SafeException("Invalid value for integer attribute '%s': %s" % (attr_name, val))
	return val

class ZeroInstallFeed(object):
	"""A feed lists available implementations of an interface.
	@ivar url: the URL for this feed
	@ivar implementations: Implementations in this feed, indexed by ID
	@type implementations: {str: L{Implementation}}
	@ivar name: human-friendly name
	@ivar summary: short textual description
	@ivar description: long textual description
	@ivar last_modified: timestamp on signature
	@ivar last_checked: time feed was last successfully downloaded and updated
	@ivar feeds: list of <feed> elements in this feed
	@type feeds: [L{Feed}]
	@ivar feed_for: interfaces for which this could be a feed
	@type feed_for: set(str)
	@ivar metadata: extra elements we didn't understand
	"""
	# _main is deprecated
	__slots__ = ['url', 'implementations', 'name', 'description', 'summary',
		     'last_checked', 'last_modified', 'feeds', 'feed_for', 'metadata']

	def __init__(self, feed_element, local_path = None, distro = None):
		"""Create a feed object from a DOM.
		@param feed_element: the root element of a feed file
		@type feed_element: L{qdom.Element}
		@param local_path: the pathname of this local feed, or None for remote feeds
		@param distro: used to resolve distribution package references
		@type distro: L{distro.Distribution} or None"""
		assert feed_element
		self.implementations = {}
		self.name = None
		self.summary = None
		self.description = ""
		self.last_modified = None
		self.feeds = []
		self.feed_for = set()
		self.metadata = []
		self.last_checked = None

		assert feed_element.name in ('interface', 'feed'), "Root element should be <interface>, not %s" % feed_element
		assert feed_element.uri == XMLNS_IFACE, "Wrong namespace on root element: %s" % feed_element.uri

		main = feed_element.getAttribute('main')
		#if main: warn("Setting 'main' on the root element is deprecated. Put it on a <group> instead")

		if local_path:
			self.url = local_path
			local_dir = os.path.dirname(local_path)
		else:
			self.url = feed_element.getAttribute('uri')
			if not self.url:
				raise InvalidInterface("<interface> uri attribute missing")
			local_dir = None	# Can't have relative paths

		min_injector_version = feed_element.getAttribute('min-injector-version')
		if min_injector_version:
			if parse_version(min_injector_version) > parse_version(version):
				raise InvalidInterface("This feed requires version %s or later of "
							"Zero Install, but I am only version %s. "
							"You can get a newer version from http://0install.net" %
							(min_injector_version, version))

		for x in feed_element.childNodes:
			if x.uri != XMLNS_IFACE:
				self.metadata.append(x)
				continue
			if x.name == 'name':
				self.name = x.content
			elif x.name == 'description':
				self.description = x.content
			elif x.name == 'summary':
				self.summary = x.content
			elif x.name == 'feed-for':
				feed_iface = x.getAttribute('interface')
				if not feed_iface:
					raise InvalidInterface('Missing "interface" attribute in <feed-for>')
				self.feed_for.add(feed_iface)
				# Bug report from a Debian/stable user that --feed gets the wrong value.
				# Can't reproduce (even in a Debian/stable chroot), but add some logging here
				# in case it happens again.
				debug("Is feed-for %s", feed_iface)
			elif x.name == 'feed':
				feed_src = x.getAttribute('src')
				if not feed_src:
					raise InvalidInterface('Missing "src" attribute in <feed>')
				if feed_src.startswith('http:') or local_path:
					self.feeds.append(Feed(feed_src, x.getAttribute('arch'), False, langs = x.getAttribute('langs')))
				else:
					raise InvalidInterface("Invalid feed URL '%s'" % feed_src)
			else:
				self.metadata.append(x)

		if not self.name:
			raise InvalidInterface("Missing <name> in feed")
		if not self.summary:
			raise InvalidInterface("Missing <summary> in feed")

		def process_group(group, group_attrs, base_depends, base_bindings):
			for item in group.childNodes:
				if item.uri != XMLNS_IFACE: continue

				if item.name not in ('group', 'implementation', 'package-implementation'):
					continue

				depends = base_depends[:]
				bindings = base_bindings[:]

				item_attrs = _merge_attrs(group_attrs, item)

				# We've found a group or implementation. Scan for dependencies
				# and bindings. Doing this here means that:
				# - We can share the code for groups and implementations here.
				# - The order doesn't matter, because these get processed first.
				# A side-effect is that the document root cannot contain
				# these.
				for child in item.childNodes:
					if child.uri != XMLNS_IFACE: continue
					if child.name == 'requires':
						dep = process_depends(child)
						depends.append(dep)
					elif child.name in binding_names:
						bindings.append(process_binding(child))

				if item.name == 'group':
					process_group(item, item_attrs, depends, bindings)
				elif item.name == 'implementation':
					process_impl(item, item_attrs, depends, bindings)
				elif item.name == 'package-implementation':
					process_native_impl(item, item_attrs, depends)
				else:
					assert 0

		def process_impl(item, item_attrs, depends, bindings):
			id = item.getAttribute('id')
			if id is None:
				raise InvalidInterface("Missing 'id' attribute on %s" % item)
			if local_dir and (id.startswith('/') or id.startswith('.')):
				impl = self._get_impl(os.path.abspath(os.path.join(local_dir, id)))
			else:
				if '=' not in id:
					raise InvalidInterface('Invalid "id"; form is "alg=value" (got "%s")' % id)
				alg, sha1 = id.split('=')
				try:
					long(sha1, 16)
				except Exception, ex:
					raise InvalidInterface('Bad SHA1 attribute: %s' % ex)
				impl = self._get_impl(id)

			impl.metadata = item_attrs
			try:
				version = item_attrs['version']
				version_mod = item_attrs.get('version-modifier', None)
				if version_mod: version += version_mod
			except KeyError:
				raise InvalidInterface("Missing version attribute")
			impl.version = parse_version(version)

			item_main = item_attrs.get('main', None)
			if item_main and item_main.startswith('/'):
				raise InvalidInterface("'main' attribute must be relative, but '%s' starts with '/'!" %
							item_main)
			impl.main = item_main

			impl.released = item_attrs.get('released', None)
			impl.langs = item_attrs.get('langs', None)

			size = item.getAttribute('size')
			if size:
				impl.size = long(size)
			impl.arch = item_attrs.get('arch', None)
			try:
				stability = stability_levels[str(item_attrs['stability'])]
			except KeyError:
				stab = str(item_attrs['stability'])
				if stab != stab.lower():
					raise InvalidInterface('Stability "%s" invalid - use lower case!' % item_attrs.stability)
				raise InvalidInterface('Stability "%s" invalid' % item_attrs['stability'])
			if stability >= preferred:
				raise InvalidInterface("Upstream can't set stability to preferred!")
			impl.upstream_stability = stability

			impl.bindings = bindings
			impl.requires = depends

			for elem in item.childNodes:
				if elem.uri != XMLNS_IFACE: continue
				if elem.name == 'archive':
					url = elem.getAttribute('href')
					if not url:
						raise InvalidInterface("Missing href attribute on <archive>")
					size = elem.getAttribute('size')
					if not size:
						raise InvalidInterface("Missing size attribute on <archive>")
					impl.add_download_source(url = url, size = long(size),
							extract = elem.getAttribute('extract'),
							start_offset = _get_long(elem, 'start-offset'),
							type = elem.getAttribute('type'))
				elif elem.name == 'recipe':
					recipe = Recipe()
					for recipe_step in elem.childNodes:
						if recipe_step.uri == XMLNS_IFACE and recipe_step.name == 'archive':
							url = recipe_step.getAttribute('href')
							if not url:
								raise InvalidInterface("Missing href attribute on <archive>")
							size = recipe_step.getAttribute('size')
							if not size:
								raise InvalidInterface("Missing size attribute on <archive>")
							recipe.steps.append(DownloadSource(None, url = url, size = long(size),
									extract = recipe_step.getAttribute('extract'),
									start_offset = _get_long(recipe_step, 'start-offset'),
									type = recipe_step.getAttribute('type')))
						else:
							info("Unknown step '%s' in recipe; skipping recipe", recipe_step.name)
							break
					else:
						impl.download_sources.append(recipe)

		def process_native_impl(item, item_attrs, depends):
			package = item_attrs.get('package', None)
			if package is None:
				raise InvalidInterface("Missing 'package' attribute on %s" % item)

			def factory(id):
				assert id.startswith('package:')
				impl = self._get_impl(id)

				impl.metadata = item_attrs

				item_main = item_attrs.get('main', None)
				if item_main and not item_main.startswith('/'):
					raise InvalidInterface("'main' attribute must be absolute, but '%s' doesn't start with '/'!" %
								item_main)
				impl.main = item_main
				impl.upstream_stability = packaged
				impl.requires = depends

				return impl

			distro.get_package_info(package, factory)
		
		process_group(feed_element,
			{'stability': 'testing',
			 'main' : main,
			},
			[], [])

	def get_name(self):
		return self.name or '(' + os.path.basename(self.url) + ')'
	
	def __repr__(self):
		return "<Feed %s>" % self.url
	
	def _get_impl(self, id):
		if id not in self.implementations:
			if id.startswith('package:'):
				impl = DistributionImplementation(self, id)
			else:
				impl = ZeroInstallImplementation(self, id)
			self.implementations[id] = impl
		return self.implementations[id]
	
	def set_stability_policy(self, new):
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new
	
	def get_feed(self, url):
		for x in self.feeds:
			if x.uri == url:
				return x
		return None
	
	def add_metadata(self, elem):
		self.metadata.append(elem)
	
	def get_metadata(self, uri, name):
		"""Return a list of interface metadata elements with this name and namespace URI."""
		return [m for m in self.metadata if m.name == name and m.uri == uri]

class DummyFeed(object):
	"""Temporary class used during API transition."""
	last_modified = None
	name = '-'
	last_checked = property(lambda self: None)
	implementations = property(lambda self: {})
	feeds = property(lambda self: [])
	summary = property(lambda self: '-')
	description = property(lambda self: '')
	def get_name(self): return self.name
	def get_feed(self, url): return None
	def get_metadata(self, uri, name): return []
_dummy_feed = DummyFeed()

def unescape(uri):
	"""Convert each %20 to a space, etc.
	@rtype: str"""
	uri = uri.replace('#', '/')
	if '%' not in uri: return uri
	return re.sub('%[0-9a-fA-F][0-9a-fA-F]',
		lambda match: chr(int(match.group(0)[1:], 16)),
		uri).decode('utf-8')

def escape(uri):
	"""Convert each space to %20, etc
	@rtype: str"""
	return re.sub('[^-_.a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8'))

def _pretty_escape(uri):
	"""Convert each space to %20, etc
	: is preserved and / becomes #. This makes for nicer strings,
	and may replace L{escape} everywhere in future.
	@rtype: str"""
	return re.sub('[^-_.a-zA-Z0-9:/]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8')).replace('/', '#')

def canonical_iface_uri(uri):
	"""If uri is a relative path, convert to an absolute one.
	A "file:///foo" URI is converted to "/foo".
	Otherwise, return it unmodified.
	@rtype: str
	@raise SafeException: if uri isn't valid
	"""
	if uri.startswith('http:'):
		return uri
	elif uri.startswith('file:///'):
		return uri[7:]
	else:
		iface_uri = os.path.realpath(uri)
		if os.path.isfile(iface_uri):
			return iface_uri
	raise SafeException("Bad interface name '%s'.\n"
			"(doesn't start with 'http:', and "
			"doesn't exist as a local file '%s' either)" %
			(uri, iface_uri))

_version_mod_to_value = {
	'pre': -2,
	'rc': -1,
	'': 0,
	'post': 1,
}

# Reverse mapping
_version_value_to_mod = {}
for x in _version_mod_to_value: _version_value_to_mod[_version_mod_to_value[x]] = x
del x

_version_re = re.compile('-([a-z]*)')

def parse_version(version_string):
	"""Convert a version string to an internal representation.
	The parsed format can be compared quickly using the standard Python functions.
	 - Version := DottedList ("-" Mod DottedList?)*
	 - DottedList := (Integer ("." Integer)*)
	@rtype: tuple (opaque)
	@raise SafeException: if the string isn't a valid version
	@since: 0.24 (moved from L{reader}, from where it is still available):"""
	if version_string is None: return None
	parts = _version_re.split(version_string)
	if parts[-1] == '':
		del parts[-1]	# Ends with a modifier
	else:
		parts.append('')
	if not parts:
		raise SafeException("Empty version string!")
	l = len(parts)
	try:
		for x in range(0, l, 2):
			part = parts[x]
			if part:
				parts[x] = map(int, parts[x].split('.'))
			else:
				parts[x] = []	# (because ''.split('.') == [''], not [])
		for x in range(1, l, 2):
			parts[x] = _version_mod_to_value[parts[x]]
		return parts
	except ValueError, ex:
		raise SafeException("Invalid version format in '%s': %s" % (version_string, ex))
	except KeyError, ex:
		raise SafeException("Invalid version modifier in '%s': %s" % (version_string, ex))

def format_version(version):
	"""Format a parsed version for display. Undoes the effect of L{parse_version}.
	@see: L{Implementation.get_version}
	@rtype: str
	@since: 0.24"""
	version = version[:]
	l = len(version)
	for x in range(0, l, 2):
		version[x] = '.'.join(map(str, version[x]))
	for x in range(1, l, 2):
		version[x] = '-' + _version_value_to_mod[version[x]]
	if version[-1] == '-': del version[-1]
	return ''.join(version)

