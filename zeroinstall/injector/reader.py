"""
Parses an XML feed into a Python representation. You should probably use L{iface_cache.iface_cache} rather than the functions here.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from logging import debug, info, warn

from zeroinstall.support import basedir
from zeroinstall.injector import qdom, distro
from zeroinstall.injector.namespaces import config_site, config_prog, XMLNS_IFACE
from zeroinstall.injector.model import Interface, InvalidInterface, ZeroInstallFeed, escape, Feed, stability_levels
from zeroinstall.injector import model

def update_from_cache(interface):
	"""Read a cached interface and any native feeds or user overrides.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@return: True if cached version and user overrides loaded OK.
	False if upstream not cached. Local interfaces (starting with /) are
	always considered to be cached, although they are not actually stored in the cache.
	@rtype: bool"""
	interface.reset()
	from zeroinstall.injector.iface_cache import iface_cache
	main_feed = iface_cache.get_feed(interface.uri, force = True)

	# Add the distribution package manager's version, if any
	path = basedir.load_first_data(config_site, 'native_feeds', model._pretty_escape(interface.uri))
	if path:
		# Resolve any symlinks
		info(_("Adding native packager feed '%s'"), path)
		interface.extra_feeds.append(Feed(os.path.realpath(path), None, False))

	update_user_overrides(interface, main_feed)

	return main_feed is not None

def load_feed_from_cache(url):
	"""Load a feed. If the feed is remote, load from the cache. If local, load it directly.
	@return: the feed, or None if it's remote and not cached."""
	if os.path.isabs(url):
		debug(_("Loading local feed file '%s'"), url)
		return load_feed(url, local = True)
	else:
		cached = basedir.load_first_cache(config_site, 'interfaces', escape(url))
		if cached:
			debug(_("Loading cached information for %(interface)s from %(cached)s"), {'interface': url, 'cached': cached})
			return load_feed(cached, local = False)
		else:
			return None

def update_user_overrides(interface, main_feed = None):
	"""Update an interface with user-supplied information.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@param main_feed: feed to update with last_checked information
	@note: feed updates shouldn't really be here. main_feed may go away in future.
	"""
	user = basedir.load_first_config(config_site, config_prog,
					   'user_overrides', escape(interface.uri))
	if not user:
		return

	try:
		root = qdom.parse(file(user))
	except Exception, ex:
		warn(_("Error reading '%(user)s': %(exception)s"), {'user': user, 'exception': ex})
		raise

	# This is a bit wrong; this information is about the feed,
	# not the interface.
	if main_feed:
		last_checked = root.getAttribute('last-checked')
		if last_checked:
			main_feed.last_checked = int(last_checked)

	stability_policy = root.getAttribute('stability-policy')
	if stability_policy:
		interface.set_stability_policy(stability_levels[str(stability_policy)])

	for item in root.childNodes:
		if item.uri != XMLNS_IFACE: continue
		if item.name == 'implementation':
			id = item.getAttribute('id')
			assert id is not None
			if not (os.path.isabs(id) or id.startswith('.') or id.startswith('package:')):
				assert '=' in id
			if main_feed:
				impl = main_feed.implementations.get(id, None)
			else:
				impl = None
			if not impl:
				debug(_("Ignoring user-override for unknown implementation %(id)s in %(interface)s"), {'id': id, 'interface': interface})
				continue

			user_stability = item.getAttribute('user-stability')
			if user_stability:
				impl.user_stability = stability_levels[str(user_stability)]
		elif item.name == 'feed':
			feed_src = item.getAttribute('src')
			if not feed_src:
				raise InvalidInterface(_('Missing "src" attribute in <feed>'))
			interface.extra_feeds.append(Feed(feed_src, item.getAttribute('arch'), True, langs = item.getAttribute('langs')))

def check_readable(feed_url, source):
	"""Test whether a feed file is valid.
	@param feed_url: the feed's expected URL
	@type feed_url: str
	@param source: the name of the file to test
	@type source: str
	@return: the modification time in src (usually just the mtime of the file)
	@rtype: int
	@raise InvalidInterface: If the source's syntax is incorrect,
	"""
	try:
		feed = load_feed(source, local = False)

		if feed.url != feed_url:
			raise InvalidInterface(_("Incorrect URL used for feed.\n\n"
						"%(feed_url)s is given in the feed, but\n"
						"%(interface_uri)s was requested") %
						{'feed_url': feed.url, 'interface_uri': feed_url})
		return feed.last_modified
	except InvalidInterface, ex:
		info(_("Error loading feed:\n"
			"Interface URI: %(uri)s\n"
			"Local file: %(source)s\n"
			"%(exception)s") %
			{'uri': feed_url, 'source': source, 'exception': ex})
		raise InvalidInterface(_("Error loading feed '%(uri)s':\n\n%(exception)s") % {'uri': feed_url, 'exception': ex})

def update(interface, source, local = False):
	"""Read in information about an interface.
	Deprecated.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@param source: the name of the file to read
	@type source: str
	@param local: use file's mtime for last-modified, and uri attribute is ignored
	@raise InvalidInterface: if the source's syntax is incorrect
	@return: the new feed (since 0.32)
	@see: L{update_from_cache}, which calls this"""
	assert isinstance(interface, Interface)

	feed = load_feed(source, local)

	if not local:
		if feed.url != interface.uri:
			raise InvalidInterface(_("Incorrect URL used for feed.\n\n"
						"%(feed_url)s is given in the feed, but\n"
						"%(interface_uri)s was requested") %
						{'feed_url': feed.url, 'interface_uri': interface.uri})

	# Hack.
	from zeroinstall.injector.iface_cache import iface_cache
	iface_cache._feeds[unicode(interface.uri)] = feed

	return feed

def load_feed(source, local = False):
	"""Load a feed from a local file.
	@param source: the name of the file to read
	@type source: str
	@param local: this is a local feed
	@type local: bool
	@raise InvalidInterface: if the source's syntax is incorrect
	@return: the new feed
	@since: 0.48
	@see: L{iface_cache.iface_cache}, which uses this to load the feeds"""
	try:
		root = qdom.parse(file(source))
	except IOError, ex:
		if ex.errno == 2:
			raise InvalidInterface(_("Feed not found. Perhaps this is a local feed that no longer exists? You can remove it from the list of feeds in that case."), ex)
		raise InvalidInterface(_("Can't read file"), ex)
	except Exception, ex:
		raise InvalidInterface(_("Invalid XML"), ex)

	if local:
		local_path = source
	else:
		local_path = None
	feed = ZeroInstallFeed(root, local_path, distro.get_host_distribution())
	feed.last_modified = int(os.stat(source).st_mtime)
	return feed
