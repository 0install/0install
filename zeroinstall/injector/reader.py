"""
Parses an XML interface into a Python representation.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
import sys
import shutil
import time
from logging import debug, warn, info
from os.path import dirname

from zeroinstall.injector import basedir, qdom
from zeroinstall.injector.namespaces import *
from zeroinstall.injector.model import *
from zeroinstall import version, SafeException

class InvalidInterface(SafeException):
	"""Raised when parsing an invalid interface."""
	def __init__(self, message, ex = None):
		if ex:
			message += "\n\n(exact error: %s)" % ex
		SafeException.__init__(self, message)

def _process_depends(dependency, item):
	# Note: also called from selections
	for e in item.childNodes:
		if e.uri != XMLNS_IFACE: continue
		if e.name == 'environment':
			binding = EnvironmentBinding(e.getAttribute('name'),
						     insert = e.getAttribute('insert'),
						     default = e.getAttribute('default'))
			if not binding.name: raise InvalidInterface("Missing 'name' in binding")
			if binding.insert is None: raise InvalidInterface("Missing 'insert' in binding")
			dependency.bindings.append(binding)
		elif e.name == 'version':
			dependency.restrictions.append(
				Restriction(not_before = parse_version(e.getAttribute('not-before')),
					    before = parse_version(e.getAttribute('before'))))

def update_from_cache(interface):
	"""Read a cached interface and any user overrides.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@return: True if cached version and user overrides loaded OK.
	False if upstream not cached. Local interfaces (starting with /) are
	always considered to be cached, although they are not actually stored in the cache.
	@rtype: bool"""
	interface.reset()

	if interface.uri.startswith('/'):
		debug("Loading local interface file '%s'", interface.uri)
		update(interface, interface.uri, local = True)
		interface.last_modified = int(os.stat(interface.uri).st_mtime)
		cached = True
	else:
		cached = basedir.load_first_cache(config_site, 'interfaces', escape(interface.uri))
		if cached:
			debug("Loading cached information for %s from %s", interface, cached)
			update(interface, cached)

	update_user_overrides(interface)

	# Special case: add our fall-back local copy of the injector as a feed
	if interface.uri == injector_gui_uri:
		local_gui = os.path.join(os.path.abspath(dirname(dirname(__file__))), '0launch-gui', 'ZeroInstall-GUI.xml')
		interface.feeds.append(Feed(local_gui, None, False))

	return bool(cached)

def update_user_overrides(interface):
	"""Update an interface with user-supplied information.
	@param interface: the interface object to update
	@type interface: L{model.Interface}"""
	user = basedir.load_first_config(config_site, config_prog,
					   'user_overrides', escape(interface.uri))
	if not user:
		return

	root = qdom.parse(file(user))

	last_checked = root.getAttribute('last-checked')
	if last_checked:
		interface.last_checked = int(last_checked)

	last_check_attempt = root.getAttribute('last-check-attempt')
	if last_check_attempt:
		interface.last_check_attempt = int(last_check_attempt)

	stability_policy = root.getAttribute('stability-policy')
	if stability_policy:
		interface.set_stability_policy(stability_levels[str(stability_policy)])

	for item in root.childNodes:
		if item.uri != XMLNS_IFACE: continue
		if item.name == 'implementation':
			id = item.getAttribute('id')
			assert id is not None
			if not (id.startswith('/') or id.startswith('.')):
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
			interface.feeds.append(Feed(feed_src, item.getAttribute('arch'), True))

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
		info("Error loading interface:\n"
			"Interface URI: %s\n"
			"Local file: %s\n%s" %
			(interface_uri, source, ex))
		raise InvalidInterface("Error loading feed '%s':\n\n%s" % (interface_uri, ex))
	return tmp.last_modified

def _parse_time(t):
	try:
		return long(t)
	except Exception, ex:
		raise InvalidInterface("Date '%s' not in correct format (should be integer number "
					"of seconds since Unix epoch)\n%s" % (t, ex))

def _check_canonical_name(interface, root):
	"Ensure the uri= attribute in the interface file matches the interface we are trying to load"
	canonical_name = root.getAttribute('uri')
	if not canonical_name:
		raise InvalidInterface("<interface> uri attribute missing")
	if canonical_name != interface.uri:
		raise InvalidInterface("Incorrect URL used for feed.\n\n"
					"%s is given in the feed, but\n"
					"%s was requested" %
					(canonical_name, interface.uri))
	
def _get_long(elem, attr_name):
	val = elem.getAttribute(attr_name)
	if val is not None:
		try:
			val = long(val)
		except ValueError, ex:
			raise SafeException("Invalid value for integer attribute '%s': %s" % (attr_name, val))
	return val

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

def update(interface, source, local = False):
	"""Read in information about an interface.
	@param interface: the interface object to update
	@type interface: L{model.Interface}
	@param source: the name of the file to read
	@type source: str
	@param local: use file's mtime for last-modified, and uri attribute is ignored
	@raise InvalidInterface: if the source's syntax is incorrect
	@see: L{update_from_cache}, which calls this"""
	assert isinstance(interface, Interface)

	try:
		root = qdom.parse(file(source))
	except Exception, ex:
		raise InvalidInterface("Invalid XML", ex)

	if not local:
		_check_canonical_name(interface, root)
		time_str = root.getAttribute('last-modified')
		if time_str:
			# Old style cached items use an attribute
			interface.last_modified = _parse_time(time_str)
		else:
			# New style items have the mtime in the signature,
			# but for quick access we use the mtime of the file
			interface.last_modified = int(os.stat(source).st_mtime)
	main = root.getAttribute('main')
	if main:
		interface.main = main

	min_injector_version = root.getAttribute('min-injector-version')
	if min_injector_version:
		try:
			min_ints = map(int, min_injector_version.split('.'))
		except ValueError, ex:
			raise InvalidInterface("Bad version number '%s'" % min_injector_version)
		injector_version = map(int, version.split('.'))
		if min_ints > injector_version:
			raise InvalidInterface("This interface requires version %s or later of "
						"the Zero Install injector, but I am only version %s. "
						"You can get a newer version from http://0install.net" %
						(min_injector_version, version))

	if local:
		iface_dir = os.path.dirname(source)
	else:
		iface_dir = None	# Can't have relative paths
	
	for x in root.childNodes:
		if x.uri != XMLNS_IFACE:
			interface.add_metadata(x)
			continue
		if x.name == 'name':
			interface.name = interface.name or x.content
		elif x.name == 'description':
			interface.description = interface.description or x.content
		elif x.name == 'summary':
			interface.summary = interface.summary or x.content
		elif x.name == 'feed-for':
			feed_iface = x.getAttribute('interface')
			if not feed_iface:
				raise InvalidInterface('Missing "interface" attribute in <feed-for>')
			interface.feed_for[feed_iface] = True
			# Bug report from a Debian/stable user that --feed gets the wrong value.
			# Can't reproduce (even in a Debian/stable chroot), but add some logging here
			# in case it happens again.
			debug("Is feed-for %s", feed_iface)
		elif x.name == 'feed':
			feed_src = x.getAttribute('src')
			if not feed_src:
				raise InvalidInterface('Missing "src" attribute in <feed>')
			if feed_src.startswith('http:') or local:
				interface.feeds.append(Feed(feed_src, x.getAttribute('arch'), False))
			else:
				raise InvalidInterface("Invalid feed URL '%s'" % feed_src)
		else:
			interface.add_metadata(x)

	def process_group(group, group_attrs, base_depends):
		for item in group.childNodes:
			if item.uri != XMLNS_IFACE: continue

			depends = base_depends.copy()

			item_attrs = _merge_attrs(group_attrs, item)

			for child in item.childNodes:
				if child.uri != XMLNS_IFACE: continue
				if child.name == 'requires':
					dep_iface = child.getAttribute('interface')
					if dep_iface is None:
						raise InvalidInterface("Missing 'interface' on <requires>")
					dep = Dependency(dep_iface, metadata = child.attrs)
					_process_depends(dep, child)
					depends[dep.interface] = dep

			if item.name == 'group':
				process_group(item, item_attrs, depends)
			elif item.name == 'implementation':
				process_impl(item, item_attrs, depends)
	
	def process_impl(item, item_attrs, depends):
		id = item.getAttribute('id')
		if id is None:
			raise InvalidInterface("Missing 'id' attribute on %s" % item)
		if local and (id.startswith('/') or id.startswith('.')):
			impl = interface.get_impl(os.path.abspath(os.path.join(iface_dir, id)))
		else:
			if '=' not in id:
				raise InvalidInterface('Invalid "id"; form is "alg=value" (got "%s")' % id)
			alg, sha1 = id.split('=')
			try:
				long(sha1, 16)
			except Exception, ex:
				raise InvalidInterface('Bad SHA1 attribute: %s' % ex)
			impl = interface.get_impl(id)

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

		impl.dependencies.update(depends)

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

	process_group(root,
		{'stability': 'testing',
	         'main' : root.getAttribute('main') or None,
		},
		{})
