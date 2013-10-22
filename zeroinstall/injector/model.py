"""In-memory representation of interfaces and other data structures.

The objects in this module are used to build a representation of an XML interface
file in memory.

@see: L{reader} constructs these data-structures
@see: U{http://0install.net/interface-spec.html} description of the domain model

@var defaults: Default values for the 'default' attribute for <environment> bindings of
well-known variables.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import os, re, locale, sys
from zeroinstall import SafeException, version
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.versions import parse_version, format_version
from zeroinstall import support
from zeroinstall.support import escaping

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
	feed_url = None

	def __init__(self, message, ex = None):
		"""@type message: str"""
		if ex:
			try:
				message += "\n\n(exact error: %s)" % ex
			except:
				# Some Python messages have type str but contain UTF-8 sequences.
				# (e.g. IOException). Adding these to a Unicode 'message' (e.g.
				# after gettext translation) will cause an error.
				import codecs
				decoder = codecs.lookup('utf-8')
				decex = decoder.decode(str(ex), errors = 'replace')[0]
				message += "\n\n(exact error: %s)" % decex

		SafeException.__init__(self, message)

	def __unicode__(self):
		"""@rtype: str"""
		if hasattr(SafeException, '__unicode__'):
			# Python >= 2.6
			if self.feed_url:
				return _('%s [%s]') % (SafeException.__unicode__(self), self.feed_url)
			return SafeException.__unicode__(self)
		else:
			return support.unicode(SafeException.__str__(self))

def _split_arch(arch):
	"""Split an arch into an (os, machine) tuple. Either or both parts may be None.
	@type arch: str"""
	if not arch:
		return None, None
	elif '-' not in arch:
		raise SafeException(_("Malformed arch '%s'") % arch)
	else:
		osys, machine = arch.split('-', 1)
		if osys == '*': osys = None
		if machine == '*': machine = None
		return osys, machine

def _join_arch(osys, machine):
	"""@type osys: str
	@type machine: str
	@rtype: str"""
	if osys == machine == None: return None
	return "%s-%s" % (osys or '*', machine or '*')

def _best_language_match(options):
	"""@type options: {str: str}
	@rtype: str"""
	(language, encoding) = locale.getlocale()

	if language:
		# xml:lang uses '-', while LANG uses '_'
		language = language.replace('_', '-')
	else:
		language = 'en-US'

	return (options.get(language, None) or			# Exact match (language+region)
		options.get(language.split('-', 1)[0], None) or	# Matching language
		options.get('en', None))			# English

class Stability(object):
	"""A stability rating. Each implementation has an upstream stability rating and,
	optionally, a user-set rating."""
	__slots__ = ['level', 'name', 'description']
	def __init__(self, level, name, description):
		"""@type level: int
		@type name: str
		@type description: str"""
		self.level = level
		self.name = name
		self.description = description
		assert name not in stability_levels
		stability_levels[name] = self

	def __cmp__(self, other):
		"""@type other: L{Stability}
		@rtype: int"""
		return cmp(self.level, other.level)

	def __lt__(self, other):
		"""@type other: L{Stability}
		@rtype: bool"""
		if isinstance(other, Stability):
			return self.level < other.level
		else:
			return NotImplemented

	def __eq__(self, other):
		"""@type other: L{Stability}
		@rtype: bool"""
		if isinstance(other, Stability):
			return self.level == other.level
		else:
			return NotImplemented

	def __str__(self):
		"""@rtype: str"""
		return self.name

	def __repr__(self):
		return _("<Stability: %s>") % self.description

def N_(message): return message

insecure = Stability(0, N_('insecure'), _('This is a security risk'))
buggy = Stability(5, N_('buggy'), _('Known to have serious bugs'))
developer = Stability(10, N_('developer'), _('Work-in-progress - bugs likely'))
testing = Stability(20, N_('testing'), _('Stability unknown - please test!'))
stable = Stability(30, N_('stable'), _('Tested - no serious problems found'))
packaged = Stability(35, N_('packaged'), _('Supplied by the local package manager'))
preferred = Stability(40, N_('preferred'), _('Best of all - must be set manually'))

del N_

class Restriction(object):
	"""A Restriction limits the allowed implementations of an Interface."""
	__slots__ = []

	reason = _("Incompatible with user-specified requirements")

	def meets_restriction(self, impl):
		"""Called by the L{solver.Solver} to check whether a particular implementation is acceptable.
		@return: False if this implementation is not a possibility
		@rtype: bool"""
		raise NotImplementedError(_("Abstract"))

	def __str__(self):
		return "missing __str__ on %s" % type(self)

	def __repr__(self):
		"""@rtype: str"""
		return "<restriction: %s>" % self

class Feed(object):
	"""An interface's feeds are other interfaces whose implementations can also be
	used as implementations of this interface."""
	__slots__ = ['uri', 'os', 'machine', 'user_override', 'langs', 'site_package']
	def __init__(self, uri, arch, user_override, langs = None, site_package = False):
		self.uri = uri
		# This indicates whether the feed comes from the user's overrides
		# file. If true, writer.py will write it when saving.
		self.user_override = user_override
		self.os, self.machine = _split_arch(arch)
		self.langs = langs
		self.site_package = site_package

	def __str__(self):
		return "<Feed from %s>" % self.uri
	__repr__ = __str__

	arch = property(lambda self: _join_arch(self.os, self.machine))

class RetrievalMethod(object):
	"""A RetrievalMethod provides a way to fetch an implementation."""
	__slots__ = []

	requires_network = True		# Used to decide if we can get this in off-line mode

class DistributionSource(RetrievalMethod):
	"""A package that is installed using the distribution's tools (including PackageKit).
	@ivar package_id: the package name, in a form recognised by the distribution's tools
	@type package_id: str
	@ivar size: the download size in bytes
	@type size: int
	@ivar needs_confirmation: whether the user should be asked to confirm before calling install()
	@type needs_confirmation: bool"""

	__slots__ = ['package_id', 'size', 'needs_confirmation', 'packagekit_id']

	def __init__(self, package_id, size, needs_confirmation = True, packagekit_id = None):
		"""@type package_id: str
		@type size: int
		@type needs_confirmation: bool"""
		RetrievalMethod.__init__(self)
		self.package_id = package_id
		self.packagekit_id = packagekit_id
		self.size = size
		self.needs_confirmation = needs_confirmation

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
	@type langs: str
	@ivar requires: interfaces this package depends on
	@type requires: [L{Dependency}]
	@ivar metadata: extra metadata from the feed
	@type metadata: {"[URI ]localName": str}
	@ivar id: a unique identifier for this Implementation
	@ivar version: a parsed version number
	@ivar released: release date
	@ivar local_path: the directory containing this local implementation, or None if it isn't local (id isn't a path)
	@type local_path: str | None
	@ivar quick_test_file: a file whose existence can be used later to check whether we need to update (since 2.2)
	@type quick_test_file: str | None
	@ivar quick_test_mtime: if present, requires that quick_test_file also has the given mtime
	@type quick_test_mtime: int | None
	"""

	# Note: user_stability shouldn't really be here

	__slots__ = ['upstream_stability', 'user_stability', 'langs',
		     'requires', 'metadata', 'download_sources', 'main',
		     'id', 'feed', 'version', 'released', 'bindings', 'machine']

	quick_test_file = None
	quick_test_mtime = None

	def __init__(self, feed, id):
		"""@type feed: L{ZeroInstallFeed}
		@type id: str"""
		assert id
		self.feed = feed
		self.id = id
		self.user_stability = None
		self.upstream_stability = None
		self.metadata = {}	# [URI + " "] + localName -> value
		self.requires = []
		self.version = None
		self.released = None
		self.download_sources = []
		self.langs = ""
		self.machine = None
		self.bindings = []
		self.main = None

	def __str__(self):
		"""@rtype: str"""
		return self.id

	def __repr__(self):
		return "v%s (%s)" % (self.get_version(), self.id)

	def __cmp__(self, other):
		"""Newer versions come first
		@type other: L{Implementation}
		@rtype: int"""
		d = cmp(other.version, self.version)
		if d: return d
		# If the version number is the same, just give a stable sort order, and
		# ensure that two different implementations don't compare equal.
		d = cmp(other.feed.url, self.feed.url)
		if d: return d
		return cmp(other.id, self.id)

	def __hash__(self):
		"""@rtype: int"""
		return self.id.__hash__()

	def __eq__(self, other):
		"""@type other: L{Implementation}
		@rtype: bool"""
		return self is other

	def __le__(self, other):
		if isinstance(other, Implementation):
			if other.version < self.version: return True
			elif other.version > self.version: return False

			if other.feed.url < self.feed.url: return True
			elif other.feed.url > self.feed.url: return False

			return other.id <= self.id
		else:
			return NotImplemented

	def get_version(self):
		"""Return the version as a string.
		@rtype: str
		@see: L{format_version}"""
		return format_version(self.version)

	arch = property(lambda self: _join_arch(self.os, self.machine))

	os = None
	local_path = None
	digests = None

class DistributionImplementation(Implementation):
	"""An implementation provided by the distribution. Information such as the version
	comes from the package manager.
	@ivar package_implementation: the <package-implementation> element that generated this impl (since 1.7)
	@type package_implementation: L{qdom.Element}
	@since: 0.28"""
	__slots__ = ['distro', 'installed', 'package_implementation', 'distro_name', 'quick_test_file', 'quick_test_mtime']

	def __init__(self, feed, id, distro, package_implementation = None, distro_name = None):
		"""@type feed: L{ZeroInstallFeed}
		@type id: str
		@type distro: L{zeroinstall.injector.distro.Distribution}
		@type package_implementation: L{zeroinstall.injector.qdom.Element} | None
		@type distro_name: str | None"""
		assert id.startswith('package:')
		Implementation.__init__(self, feed, id)
		self.distro = distro
		self.installed = False
		self.package_implementation = package_implementation
		self.distro_name = distro_name or distro.name
		self.quick_test_file = None
		self.quick_test_mtime = None

		if package_implementation:
			for child in package_implementation.childNodes:
				if child.uri != XMLNS_IFACE: continue
				if child.name == 'command':
					command_name = child.attrs.get('name', None)
					if command_name == 'run':
						self.main = child.attrs.get('path')

class Interface(object):
	"""An Interface represents some contract of behaviour.
	@ivar uri: the URI for this interface.
	@ivar stability_policy: user's configured policy.
	Implementations at this level or higher are preferred.
	Lower levels are used only if there is no other choice.
	"""
	__slots__ = ['uri', 'stability_policy']

	def __init__(self, uri):
		"""@type uri: str"""
		assert uri
		if uri.startswith('http:') or uri.startswith('https:') or os.path.isabs(uri):
			self.uri = uri
		else:
			raise SafeException(_("Interface name '%s' doesn't start "
					    "with 'http:' or 'https:'") % uri)
		self.reset()

	def reset(self):
		self.stability_policy = None

	def get_name(self):
		"""@rtype: str"""
		return '(' + os.path.basename(self.uri) + ')'

	def __repr__(self):
		"""@rtype: str"""
		return _("<Interface %s>") % self.uri

	def set_stability_policy(self, new):
		"""@type new: L{Stability}"""
		assert new is None or isinstance(new, Stability)
		self.stability_policy = new

class ZeroInstallFeed(object):
	"""A feed lists available implementations of an interface.
	@ivar url: the URL for this feed
	@ivar implementations: Implementations in this feed, indexed by ID
	@type implementations: {str: L{Implementation}}
	@ivar name: human-friendly name
	@ivar summaries: short textual description (in various languages, since 0.49)
	@type summaries: {str: str}
	@ivar descriptions: long textual description (in various languages, since 0.49)
	@type descriptions: {str: str}
	@ivar last_modified: timestamp on signature
	@ivar local_path: the path of this local feed, or None if remote (since 1.7)
	@type local_path: str | None
	@ivar feeds: list of <feed> elements in this feed
	@type feeds: [L{Feed}]
	@ivar feed_for: interfaces for which this could be a feed
	@type feed_for: set(str)
	@ivar metadata: extra elements we didn't understand
	"""
	# _main is deprecated
	__slots__ = ['url', 'implementations', 'name', 'descriptions', 'first_description', 'summaries', 'first_summary',
		     'last_modified', 'feeds', 'feed_for', 'metadata', 'local_path', 'feed_element']

	def __init__(self, feed_element, local_path = None, distro = None):
		"""Create a feed object from a DOM.
		@param feed_element: the root element of a feed file
		@type feed_element: L{qdom.Element}
		@param local_path: the pathname of this local feed, or None for remote feeds
		@type local_path: str | None"""
		self.local_path = local_path
		self.implementations = {}
		self.name = None
		self.summaries = {}	# { lang: str }
		self.first_summary = None
		self.descriptions = {}	# { lang: str }
		self.first_description = None
		self.last_modified = None
		self.feeds = []
		self.feed_for = set()
		self.metadata = []
		self.feed_element = feed_element

		if distro is not None:
			import warnings
			warnings.warn("distro argument is now ignored", DeprecationWarning, 2)

		if feed_element is None:
			return			# XXX subclass?

		if feed_element.name not in ('interface', 'feed'):
			raise SafeException("Root element should be <interface>, not <%s>" % feed_element.name)
		assert feed_element.uri == XMLNS_IFACE, "Wrong namespace on root element: %s" % feed_element.uri

		if local_path:
			self.url = local_path
			local_dir = os.path.dirname(local_path)
		else:
			assert local_path is None
			self.url = feed_element.getAttribute('uri')
			if not self.url:
				raise InvalidInterface(_("<interface> uri attribute missing"))
			local_dir = None	# Can't have relative paths

		min_injector_version = feed_element.getAttribute('min-injector-version')
		if min_injector_version:
			if parse_version(min_injector_version) > parse_version(version):
				raise InvalidInterface(_("This feed requires version %(min_version)s or later of "
							"Zero Install, but I am only version %(version)s. "
							"You can get a newer version from http://0install.net") %
							{'min_version': min_injector_version, 'version': version})

		for x in feed_element.childNodes:
			if x.uri != XMLNS_IFACE:
				self.metadata.append(x)
				continue
			if x.name == 'name':
				self.name = x.content
			elif x.name == 'description':
				if self.first_description == None:
					self.first_description = x.content
				self.descriptions[x.attrs.get("http://www.w3.org/XML/1998/namespace lang", 'en')] = x.content
			elif x.name == 'summary':
				if self.first_summary == None:
					self.first_summary = x.content
				self.summaries[x.attrs.get("http://www.w3.org/XML/1998/namespace lang", 'en')] = x.content
			elif x.name == 'feed-for':
				feed_iface = x.getAttribute('interface')
				if not feed_iface:
					raise InvalidInterface(_('Missing "interface" attribute in <feed-for>'))
				self.feed_for.add(feed_iface)
				# Bug report from a Debian/stable user that --feed gets the wrong value.
				# Can't reproduce (even in a Debian/stable chroot), but add some logging here
				# in case it happens again.
				logger.debug(_("Is feed-for %s"), feed_iface)
			elif x.name == 'feed':
				feed_src = x.getAttribute('src')
				if not feed_src:
					raise InvalidInterface(_('Missing "src" attribute in <feed>'))
				if feed_src.startswith('http:') or feed_src.startswith('https:') or local_path:
					if feed_src.startswith('.'):
						feed_src = os.path.abspath(os.path.join(local_dir, feed_src))

					langs = x.getAttribute('langs')
					if langs: langs = langs.replace('_', '-')
					self.feeds.append(Feed(feed_src, x.getAttribute('arch'), False, langs = langs))
				else:
					raise InvalidInterface(_("Invalid feed URL '%s'") % feed_src)
			else:
				self.metadata.append(x)

		if not self.name:
			raise InvalidInterface(_("Missing <name> in feed"))
		if not self.summary:
			raise InvalidInterface(_("Missing <summary> in feed"))

	def get_name(self):
		"""@rtype: str"""
		return self.name or '(' + os.path.basename(self.url) + ')'

	def __repr__(self):
		return _("<Feed %s>") % self.url

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
		"""Return a list of interface metadata elements with this name and namespace URI.
		@type uri: str
		@type name: str"""
		return [m for m in self.metadata if m.name == name and m.uri == uri]

	@property
	def summary(self):
		return _best_language_match(self.summaries) or self.first_summary

	@property
	def description(self):
		return _best_language_match(self.descriptions) or self.first_description

	def get_replaced_by(self):
		"""Return the URI of the interface that replaced the one with the URI of this feed's URL.
		This is the value of the feed's <replaced-by interface'...'/> element.
		@return: the new URI, or None if it hasn't been replaced
		@rtype: str | None
		@since: 1.7"""
		for child in self.metadata:
			if child.uri == XMLNS_IFACE and child.name == 'replaced-by':
				new_uri = child.getAttribute('interface')
				if new_uri and (new_uri.startswith('http:') or new_uri.startswith('https:') or self.local_path):
					return new_uri
		return None

if sys.version_info[0] > 2:
	# Python 3

	from functools import total_ordering
	# (note: delete these two lines when generating epydoc)
	Stability = total_ordering(Stability)
	Implementation = total_ordering(Implementation)

	# These could be replaced by urllib.parse.quote, except that
	# it uses upper-case escapes and we use lower-case ones...
	def unescape(uri):
		"""Convert each %20 to a space, etc.
		@type uri: str
		@rtype: str"""
		uri = uri.replace('#', '/')
		if '%' not in uri: return uri
		return re.sub(b'%[0-9a-fA-F][0-9a-fA-F]',
			lambda match: bytes([int(match.group(0)[1:], 16)]),
			uri.encode('ascii')).decode('utf-8')

	def escape(uri):
		"""Convert each space to %20, etc
		@type uri: str
		@rtype: str"""
		return re.sub(b'[^-_.a-zA-Z0-9]',
			lambda match: ('%%%02x' % ord(match.group(0))).encode('ascii'),
			uri.encode('utf-8')).decode('ascii')

	def _pretty_escape(uri):
		"""Convert each space to %20, etc
		: is preserved and / becomes #. This makes for nicer strings,
		and may replace L{escape} everywhere in future.
		@type uri: str
		@rtype: str"""
		if os.name == "posix":
			# Only preserve : on Posix systems
			preserveRegex = b'[^-_.a-zA-Z0-9:/]'
		else:
			# Other OSes may not allow the : character in file names
			preserveRegex = b'[^-_.a-zA-Z0-9/]'
		return re.sub(preserveRegex,
			lambda match: ('%%%02x' % ord(match.group(0))).encode('ascii'),
			uri.encode('utf-8')).decode('ascii').replace('/', '#')
else:
	# Python 2

	def unescape(uri):
		"""Convert each %20 to a space, etc.
		@type uri: str
		@rtype: str"""
		uri = uri.replace('#', '/')
		if '%' not in uri: return uri
		return re.sub('%[0-9a-fA-F][0-9a-fA-F]',
			lambda match: chr(int(match.group(0)[1:], 16)),
			uri).decode('utf-8')

	def escape(uri):
		"""Convert each space to %20, etc
		@type uri: str
		@rtype: str"""
		return re.sub('[^-_.a-zA-Z0-9]',
			lambda match: '%%%02x' % ord(match.group(0)),
			uri.encode('utf-8'))

	def _pretty_escape(uri):
		"""Convert each space to %20, etc
		: is preserved and / becomes #. This makes for nicer strings,
		and may replace L{escape} everywhere in future.
		@type uri: str
		@rtype: str"""
		if os.name == "posix":
			# Only preserve : on Posix systems
			preserveRegex = '[^-_.a-zA-Z0-9:/]'
		else:
			# Other OSes may not allow the : character in file names
			preserveRegex = '[^-_.a-zA-Z0-9/]'
		return re.sub(preserveRegex,
			lambda match: '%%%02x' % ord(match.group(0)),
			uri.encode('utf-8')).replace('/', '#')

def escape_interface_uri(uri):
	"""Convert an interface URI to a list of path components.
	e.g. "http://example.com/foo.xml" becomes ["http", "example.com", "foo.xml"], while
	"file:///root/feed.xml" becomes ["file", "root__feed.xml"]
	The number of components is determined by the scheme (three for http, two for file).
	Uses L{support.escaping.underscore_escape} to escape each component.
	@type uri: str
	@rtype: [str]"""
	if uri.startswith('http://') or uri.startswith('https://'):
		scheme, rest = uri.split('://', 1)
		parts = rest.split('/', 1)
	else:
		assert os.path.isabs(uri), uri
		scheme = 'file'
		parts = [uri[1:]]
	
	return [scheme] + [escaping.underscore_escape(part) for part in parts]

def canonical_iface_uri(uri):
	"""If uri is a relative path, convert to an absolute one.
	A "file:///foo" URI is converted to "/foo".
	An "alias:prog" URI expands to the URI in the 0alias script
	Otherwise, return it unmodified.
	@type uri: str
	@rtype: str
	@raise SafeException: if uri isn't valid"""
	if uri.startswith('http://') or uri.startswith('https://'):
		if uri.count("/") < 3:
			raise SafeException(_("Missing / after hostname in URI '%s'") % uri)
		return uri
	elif uri.startswith('file:///'):
		path = uri[7:]
	elif uri.startswith('file:'):
		if uri[5] == '/':
			raise SafeException(_('Use file:///path for absolute paths, not {uri}').format(uri = uri))
		path = os.path.abspath(uri[5:])
	elif uri.startswith('alias:'):
		from zeroinstall import alias
		alias_prog = uri[6:]
		if not os.path.isabs(alias_prog):
			full_path = support.find_in_path(alias_prog)
			if not full_path:
				raise alias.NotAnAliasScript("Not found in $PATH: " + alias_prog)
		else:
			full_path = alias_prog
		return alias.parse_script(full_path).uri
	else:
		path = os.path.realpath(uri)

	if os.path.isfile(path):
		return path

	if '/' not in uri:
		alias_path = support.find_in_path(uri)
		if alias_path is not None:
			from zeroinstall import alias
			try:
				alias.parse_script(alias_path)
			except alias.NotAnAliasScript:
				pass
			else:
				raise SafeException(_("Bad interface name '{uri}'.\n"
					"(hint: try 'alias:{uri}' instead)".format(uri = uri)))

	raise SafeException(_("Bad interface name '%(uri)s'.\n"
			"(doesn't start with 'http:', and "
			"doesn't exist as a local file '%(interface_uri)s' either)") %
			{'uri': uri, 'interface_uri': path})
