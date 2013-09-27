"""
Manages the feed cache.

@var iface_cache: A singleton cache object. You should normally use this rather than
creating new cache objects.

"""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

# Note:
#
# We need to know the modification time of each interface, because we refuse
# to update to an older version (this prevents an attack where the attacker
# sends back an old version which is correctly signed but has a known bug).
#
# The way we store this is a bit complicated due to backward compatibility:
#
# - GPG-signed interfaces have their signatures removed and a last-modified
#   attribute is stored containing the date from the signature.
#
# - XML-signed interfaces are stored unmodified with their signatures. The
#   date is extracted from the signature when needed.
#
# - Older versions used to add the last-modified attribute even to files
#   with XML signatures - these files therefore have invalid signatures and
#   we extract from the attribute for these.
#
# Eventually, support for the first and third cases will be removed.

from __future__ import print_function

import os, time

from zeroinstall import _, logger
from zeroinstall.support import basedir, unicode
from zeroinstall.injector import reader
from zeroinstall.injector.namespaces import config_site
from zeroinstall.injector.model import Interface, escape, unescape
from zeroinstall import SafeException

# If we started a check within this period, don't start another one:
FAILED_CHECK_DELAY = 60 * 60	# 1 Hour

def _pretty_time(t):
	#assert isinstance(t, (int, long)), t
	"""@type t: int
	@rtype: str"""
	return time.strftime('%Y-%m-%d %H:%M:%S UTC', time.localtime(t))

class ReplayAttack(SafeException):
	"""Attempt to import a feed that's older than the one in the cache."""
	pass

class IfaceCache(object):
	"""
	The interface cache stores downloaded and verified interfaces in
	~/.cache/0install.net/interfaces (by default).

	There are methods to query the cache, add to it, check signatures, etc.

	The cache is updated by L{fetch.Fetcher}.

	Confusingly, this class is really two caches combined: the in-memory
	cache of L{model.Interface} objects, and an on-disk cache of L{model.ZeroInstallFeed}s.
	It will probably be split into two in future.

	@ivar distro: the native distribution proxy
	@type distro: L{distro.Distribution}

	@see: L{iface_cache} - the singleton IfaceCache instance.
	"""

	__slots__ = ['_interfaces', '_feeds', '_distro', '_config']

	def __init__(self, distro = None):
		"""@param distro: distribution used to fetch "distribution:" feeds (since 0.49)
		@type distro: L{distro.Distribution}, or None to use the host distribution"""
		self._interfaces = {}
		self._feeds = {}
		self._distro = distro

	@property
	def stores(self):
		from zeroinstall.injector import policy
		return policy.get_deprecated_singleton_config().stores

	@property
	def distro(self):
		if self._distro is None:
			from zeroinstall.injector.distro import get_host_distribution
			self._distro = get_host_distribution()
		return self._distro

	def get_feed(self, url, force = False):
		"""Get a feed from the cache.
		@param url: the URL of the feed
		@type url: str
		@param force: load the file from disk again
		@type force: bool
		@return: the feed, or None if it isn't cached
		@rtype: L{model.ZeroInstallFeed}"""
		if not force:
			feed = self._feeds.get(url, False)
			if feed != False:
				return feed

		if url.startswith('distribution:'):
			master_feed = self.get_feed(url.split(':', 1)[1])
			if not master_feed:
				return None	# e.g. when checking a selections document
			feed = self.distro.get_feed(master_feed)
		else:
			feed = reader.load_feed_from_cache(url)
		if feed:
			reader.update_user_feed_overrides(feed)
		self._feeds[url] = feed
		return feed

	def get_interface(self, uri):
		"""Get the interface for uri, creating a new one if required.
		New interfaces are initialised from the disk cache, but not from
		the network.
		@param uri: the URI of the interface to find
		@type uri: str
		@rtype: L{model.Interface}"""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri in self._interfaces:
			return self._interfaces[uri]

		logger.debug(_("Initialising new interface object for %s"), uri)
		self._interfaces[uri] = Interface(uri)
		reader.update_from_cache(self._interfaces[uri], iface_cache = self)
		return self._interfaces[uri]

	def list_all_interfaces(self):
		"""List all interfaces in the cache.
		@rtype: [str]"""
		all = set()
		for d in basedir.load_cache_paths(config_site, 'interfaces'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all.add(unescape(leaf))
		return list(all)	# Why not just return the set?

	def get_icon_path(self, iface):
		"""Get the path of a cached icon for an interface.
		@param iface: interface whose icon we want
		@type iface: L{Interface}
		@return: the path of the cached icon, or None if not cached.
		@rtype: str"""
		return basedir.load_first_cache(config_site, 'interface_icons',
						 escape(iface.uri))

	def get_feed_imports(self, iface):
		"""Get all feeds that add to this interface.
		This is the feeds explicitly added by the user, feeds added by the distribution,
		and feeds imported by a <feed> in the main feed (but not recursively, at present).
		@type iface: L{Interface}
		@rtype: L{Feed}
		@since: 0.48"""
		main_feed = self.get_feed(iface.uri)
		if main_feed:
			return iface.extra_feeds + main_feed.feeds
		else:
			return iface.extra_feeds

	def get_feeds(self, iface):
		"""Get all feeds for this interface. This is a mapping from feed URLs
		to ZeroInstallFeeds. It includes the interface's main feed, plus the
		resolution of every feed returned by L{get_feed_imports}. Uncached
		feeds are indicated by a value of None.
		@type iface: L{Interface}
		@rtype: {str: L{ZeroInstallFeed} | None}
		@since: 0.48"""
		main_feed = self.get_feed(iface.uri)
		results = {iface.uri: main_feed}
		for imp in iface.extra_feeds:
			try:
				results[imp.uri] = self.get_feed(imp.uri)
			except SafeException as ex:
				logger.warning("Failed to load feed '%s: %s", imp.uri, ex)
		if main_feed:
			for imp in main_feed.feeds:
				results[imp.uri] = self.get_feed(imp.uri)
		return results

	def get_implementations(self, iface):
		"""Return all implementations from all of iface's feeds.
		@type iface: L{Interface}
		@rtype: [L{Implementation}]
		@since: 0.48"""
		impls = []
		for feed in self.get_feeds(iface).values():
			if feed:
				impls += feed.implementations.values()
		return impls

iface_cache = IfaceCache()
