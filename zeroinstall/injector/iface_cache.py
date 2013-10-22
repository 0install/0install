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

class IfaceCache(object):
	"""
	The interface cache stores downloaded and verified interfaces in
	~/.cache/0install.net/interfaces (by default).

	There are methods to query the cache, add to it, check signatures, etc.

	The cache is updated by L{fetch.Fetcher}.

	Confusingly, this class is really two caches combined: the in-memory
	cache of L{model.Interface} objects, and an on-disk cache of L{model.ZeroInstallFeed}s.
	It will probably be split into two in future.

	@see: L{iface_cache} - the singleton IfaceCache instance.
	"""

	__slots__ = ['_interfaces', '_feeds']

	def __init__(self):
		self._interfaces = {}
		self._feeds = {}

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

		assert not url.startswith('distribution:'), url

		feed = reader.load_feed_from_cache(url)
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

	def get_icon_path(self, iface):
		"""Get the path of a cached icon for an interface.
		@param iface: interface whose icon we want
		@type iface: L{Interface}
		@return: the path of the cached icon, or None if not cached.
		@rtype: str"""
		return basedir.load_first_cache(config_site, 'interface_icons',
						 escape(iface.uri))

iface_cache = IfaceCache()
