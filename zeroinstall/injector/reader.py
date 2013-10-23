"""
Parses an XML feed into a Python representation. You should probably use L{iface_cache.iface_cache} rather than the functions here.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import os
import errno

from zeroinstall.support import basedir
from zeroinstall.injector import qdom
from zeroinstall.injector.namespaces import config_site
from zeroinstall.injector.model import InvalidInterface, ZeroInstallFeed, escape

class MissingLocalFeed(InvalidInterface):
	pass

def load_feed_from_cache(url):
	"""Load a feed. If the feed is remote, load from the cache. If local, load it directly.
	@type url: str
	@return: the feed, or None if it's remote and not cached.
	@rtype: L{ZeroInstallFeed} | None"""
	try:
		if os.path.isabs(url):
			logger.debug(_("Loading local feed file '%s'"), url)
			return load_feed(url, local = True)
		else:
			cached = basedir.load_first_cache(config_site, 'interfaces', escape(url))
			if cached:
				logger.debug(_("Loading cached information for %(interface)s from %(cached)s"), {'interface': url, 'cached': cached})
				return load_feed(cached, local = False)
			else:
				return None
	except InvalidInterface as ex:
		ex.feed_url = url
		raise

def load_feed(source, local = False):
	"""Load a feed from a local file.
	@param source: the name of the file to read
	@type source: str
	@param local: this is a local feed
	@type local: bool
	@return: the new feed
	@rtype: L{ZeroInstallFeed}
	@raise InvalidInterface: if the source's syntax is incorrect
	@since: 0.48
	@see: L{iface_cache.iface_cache}, which uses this to load the feeds"""
	try:
		with open(source, 'rb') as stream:
			root = qdom.parse(stream, filter_for_version = True)
	except IOError as ex:
		if ex.errno == errno.ENOENT and local:
			raise MissingLocalFeed(_("Feed not found. Perhaps this is a local feed that no longer exists? You can remove it from the list of feeds in that case."))
		raise InvalidInterface(_("Can't read file"), ex)
	except Exception as ex:
		raise InvalidInterface(_("Invalid XML"), ex)

	if local:
		assert os.path.isabs(source), source
		local_path = source
	else:
		local_path = None
	feed = ZeroInstallFeed(root, local_path)
	feed.last_modified = int(os.stat(source).st_mtime)
	return feed
