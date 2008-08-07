"""
Parses an XML interface into a Python representation.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from logging import debug, info, warn
from os.path import dirname

from zeroinstall.support import basedir
from zeroinstall.injector import qdom, distro
from zeroinstall.injector.namespaces import config_site, config_prog, XMLNS_IFACE, injector_gui_uri
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
		debug("Loading local interface file '%s'", interface.uri)
		update(interface, interface.uri, local = True)
		cached = True
	else:
		cached = basedir.load_first_cache(config_site, 'interfaces', escape(interface.uri))
		if cached:
			debug("Loading cached information for %s from %s", interface, cached)
			main_feed = update(interface, cached)

	# Add the distribution package manager's version, if any
	path = basedir.load_first_data(config_site, 'native_feeds', model._pretty_escape(interface.uri))
	if path:
		# Resolve any symlinks
		info("Adding native packager feed '%s'", path)
		interface.extra_feeds.append(Feed(os.path.realpath(path), None, False))

	update_user_overrides(interface, main_feed)

	# Special case: add our fall-back local copy of the injector as a feed
	if interface.uri == injector_gui_uri:
		local_gui = os.path.join(os.path.abspath(dirname(dirname(__file__))), '0launch-gui', 'ZeroInstall-GUI.xml')
		interface.extra_feeds.append(Feed(local_gui, None, False))

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
		warn("Error reading '%s': %s", user, ex)
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
				debug("Ignoring user-override for unknown implementation %s in %s", id, interface)
				continue

			user_stability = item.getAttribute('user-stability')
			if user_stability:
				impl.user_stability = stability_levels[str(user_stability)]
		elif item.name == 'feed':
			feed_src = item.getAttribute('src')
			if not feed_src:
				raise InvalidInterface('Missing "src" attribute in <feed>')
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
		info("Error loading feed:\n"
			"Interface URI: %s\n"
			"Local file: %s\n%s" %
			(interface_uri, source, ex))
		raise InvalidInterface("Error loading feed '%s':\n\n%s" % (interface_uri, ex))
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
			raise InvalidInterface("Feed not found. Perhaps this is a local feed that no longer exists? You can remove it from the list of feeds in that case.", ex)
		raise InvalidInterface("Can't read file", ex)
	except Exception, ex:
		raise InvalidInterface("Invalid XML", ex)
	
	if local:
		local_path = source
	else:
		local_path = None
	feed = ZeroInstallFeed(root, local_path, distro.get_host_distribution())
	feed.last_modified = int(os.stat(source).st_mtime)

	if not local:
		if feed.url != interface.uri:
			raise InvalidInterface("Incorrect URL used for feed.\n\n"
						"%s is given in the feed, but\n"
						"%s was requested" %
						(feed.url, interface.uri))
	
	interface._main_feed = feed
	return feed
