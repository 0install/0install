"""
Parses an XML interface into a Python representation.
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
	main_feed = None

	if interface.uri.startswith('/'):
		debug(_("Loading local interface file '%s'"), interface.uri)
		update(interface, interface.uri, local = True)
		cached = True
	else:
		cached = basedir.load_first_cache(config_site, 'interfaces', escape(interface.uri))
		if cached:
			debug(_("Loading cached information for %(interface)s from %(cached)s"), {'interface': interface, 'cached': cached})
			main_feed = update(interface, cached)

	# Add the distribution package manager's version, if any
	path = basedir.load_first_data(config_site, 'native_feeds', model._pretty_escape(interface.uri))
	if path:
		# Resolve any symlinks
		info(_("Adding native packager feed '%s'"), path)
		interface.extra_feeds.append(Feed(os.path.realpath(path), None, False))

	update_user_overrides(interface, main_feed)

	return bool(cached)

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
			if not (id.startswith('/') or id.startswith('.') or id.startswith('package:')):
				assert '=' in id
			impl = interface.implementations.get(id, None)
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

def check_readable(interface_uri, source):
	"""Test whether an interface file is valid.
	@param interface_uri: the interface's URI
	@type interface_uri: str
	@param source: the name of the file to test
	@type source: str
	@return: the modification time in src (usually just the mtime of the file)
	@rtype: int
	@raise InvalidInterface: If the source's syntax is incorrect,
	"""
	tmp = Interface(interface_uri)
	try:
		update(tmp, source)
	except InvalidInterface, ex:
		info(_("Error loading feed:\n"
			"Interface URI: %(uri)s\n"
			"Local file: %(source)s\n"
			"%(exception)s") %
			{'uri': interface_uri, 'source': source, 'exception': ex})
		raise InvalidInterface(_("Error loading feed '%(uri)s':\n\n%(exception)s") % {'uri': interface_uri, 'exception': ex})
	return tmp.last_modified

def update(interface, source, local = False):
	"""Read in information about an interface.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@param source: the name of the file to read
	@type source: str
	@param local: use file's mtime for last-modified, and uri attribute is ignored
	@raise InvalidInterface: if the source's syntax is incorrect
	@return: the new feed (since 0.32)
	@see: L{update_from_cache}, which calls this"""
	assert isinstance(interface, Interface)

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

	if not local:
		if feed.url != interface.uri:
			raise InvalidInterface(_("Incorrect URL used for feed.\n\n"
						"%(feed_url)s is given in the feed, but\n"
						"%(interface_uri)s was requested") %
						{'feed_url': feed.url, 'interface_uri': interface.uri})
	
	interface._main_feed = feed
	return feed
