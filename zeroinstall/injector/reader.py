"""
Parses an XML feed into a Python representation. You should probably use L{iface_cache.iface_cache} rather than the functions here.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import os
import errno

from zeroinstall import support
from zeroinstall.support import basedir
from zeroinstall.injector import qdom
from zeroinstall.injector.namespaces import config_site, config_prog, XMLNS_IFACE
from zeroinstall.injector.model import Interface, InvalidInterface, ZeroInstallFeed, escape, Feed, stability_levels
from zeroinstall.injector import model

class MissingLocalFeed(InvalidInterface):
	pass

def update_from_cache(interface, iface_cache):
	"""Read a cached interface and any native feeds or user overrides.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@type iface_cache: L{zeroinstall.injector.iface_cache.IfaceCache} | None
	@return: True if cached version and user overrides loaded OK.
	False if upstream not cached. Local interfaces (starting with /) are
	always considered to be cached, although they are not actually stored in the cache.
	@rtype: bool
	@note: internal; use L{iface_cache.IfaceCache.get_interface} instread."""
	interface.reset()
	update_user_overrides(interface)

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

def update_user_feed_overrides(feed):
	"""Update a feed with user-supplied information.
	Sets last_checked and user_stability ratings.
	@param feed: feed to update
	@type feed: L{ZeroInstallFeed}
	@since 0.49"""
	user = basedir.load_first_config(config_site, config_prog,
					   'feeds', model._pretty_escape(feed.url))
	if user is None:
		# For files saved by 0launch < 0.49
		user = basedir.load_first_config(config_site, config_prog,
						   'user_overrides', escape(feed.url))
	if not user:
		return

	try:
		with open(user, 'rb') as stream:
			root = qdom.parse(stream)
	except Exception as ex:
		logger.warning(_("Error reading '%(user)s': %(exception)s"), {'user': user, 'exception': ex})
		raise

	last_checked = root.getAttribute('last-checked')
	if last_checked:
		feed.last_checked = int(last_checked)

def update_user_overrides(interface):
	"""Update an interface with user-supplied information.
	Sets preferred stability and updates extra_feeds.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@param known_site_feeds: feeds to ignore (for backwards compatibility)
	@type known_site_feeds: {str}"""
	user = basedir.load_first_config(config_site, config_prog,
					   'interfaces', model._pretty_escape(interface.uri))
	if user is None:
		# For files saved by 0launch < 0.49
		user = basedir.load_first_config(config_site, config_prog,
						   'user_overrides', escape(interface.uri))
	if not user:
		return

	try:
		with open(user, 'rb') as stream:
			root = qdom.parse(stream)
	except Exception as ex:
		logger.warning(_("Error reading '%(user)s': %(exception)s"), {'user': user, 'exception': ex})
		raise

	stability_policy = root.getAttribute('stability-policy')
	if stability_policy:
		interface.set_stability_policy(stability_levels[str(stability_policy)])

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
