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

from zeroinstall import _
import os, re, locale, sys
from zeroinstall import SafeException, version
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.versions import parse_version, format_version
from zeroinstall import support

network_offline = 'off-line'
network_minimal = 'minimal'
network_full = 'full'
network_levels = (network_offline, network_minimal, network_full)

stability_levels = {}	# Name -> Stability

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

class Interface(object):
	"""An Interface represents some contract of behaviour.
	@ivar uri: the URI for this interface.
	@ivar stability_policy: user's configured policy.
	Implementations at this level or higher are preferred.
	Lower levels are used only if there is no other choice.
	"""
	__slots__ = ['uri']

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
		pass

	def get_name(self):
		"""@rtype: str"""
		return '(' + os.path.basename(self.uri) + ')'

	def __repr__(self):
		"""@rtype: str"""
		return _("<Interface %s>") % self.uri

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

	def __init__(self, feed_element, local_path = None):
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
		self.last_modified = None
		self.feeds = []
		self.metadata = []
		self.feed_element = feed_element

		if feed_element is None:
			return                  # XXX subclass?

		if feed_element.name not in ('interface', 'feed'):
			raise SafeException("Root element should be <interface>, not <%s>" % feed_element.name)
		assert feed_element.uri == XMLNS_IFACE, "Wrong namespace on root element: %s" % feed_element.uri

		if local_path:
			self.url = local_path
		else:
			assert local_path is None
			self.url = feed_element.getAttribute('uri')
			if not self.url:
				raise InvalidInterface(_("<interface> uri attribute missing"))

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
				pass
			elif x.name == 'summary':
				if self.first_summary == None:
					self.first_summary = x.content
				self.summaries[x.attrs.get("http://www.w3.org/XML/1998/namespace lang", 'en')] = x.content
			elif x.name == 'feed-for':
				pass
			elif x.name == 'feed':
				pass
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

if sys.version_info[0] > 2:
	# Python 3

	from functools import total_ordering
	# (note: delete these two lines when generating epydoc)
	Stability = total_ordering(Stability)

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
