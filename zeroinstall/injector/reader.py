# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys
import shutil
import time
from logging import debug, warn

import qdom
import basedir
from namespaces import *
from model import *
import os
from os.path import dirname

class InvalidInterface(SafeException):
	def __init__(self, message, ex = None):
		if ex:
			message += "\n\n(exact error: %s)" % ex
		SafeException.__init__(self, message)

def get_singleton_text(parent, ns, localName):
	elem = None
	for x in parent.childNodes:
		if x.uri == ns and x.name == localName:
			if elem:
				raise InvalidInterface('Multiple <%s> elements in <%s>' % (localName, parent.name))
			elem = x
	if elem:
		return elem.content
	raise InvalidInterface('No <%s> element in <%s>' % (localName, parent.name))

class Attrs(object):
	__slots__ = ['version', 'released', 'arch', 'stability', 'main']
	def __init__(self, **kwargs):
		for x in self.__slots__:
			setattr(self, x, kwargs.get(x, None))
	
	def merge(self, item):
		new = Attrs()
		for x in self.__slots__:
			value = item.attrs.get(x, None)
			if value is None:
				value = getattr(self, x)
			setattr(new, x, value)
		return new

def process_depends(dependency, item):
	for e in item.childNodes:
		if e.uri == XMLNS_IFACE and e.name == 'environment':
			binding = EnvironmentBinding(e.getAttribute('name'),
						     insert = e.getAttribute('insert'),
						     default = e.getAttribute('default'))
			dependency.bindings.append(binding)

def update_from_cache(interface):
	"""True if cached version and user overrides loaded OK.
	False if upstream not cached. Local interfaces (starting with /) are
	always considered to be cached, although they are not stored there."""
	interface.reset()

	if interface.uri.startswith('/'):
		debug("Loading local interface file '%s'", interface.uri)
		update(interface, interface.uri, local = True)
		interface.last_modified = os.stat(interface.uri).st_mtime
		cached = True
	else:
		cached = basedir.load_first_cache(config_site, 'interfaces', escape(interface.uri))
		if cached:
			debug("Loading cached information for %s from %s", interface, cached)
			update(interface, cached)

	update_user_overrides(interface)

	# Special case: add our fall-back local copy of the injector as a feed
	if interface.uri == injector_gui_uri:
		local_gui = os.path.join(os.path.abspath(dirname(dirname(__file__))), '0launch-gui', 'injector-gui.xml')
		interface.feeds.append(Feed(local_gui, None, False))

	return bool(cached)

def update_user_overrides(interface):
	user = basedir.load_first_config(config_site, config_prog,
					   'user_overrides', escape(interface.uri))
	if not user:
		return

	root = qdom.parse(file(user))

	last_checked = root.getAttribute('last-checked')
	if last_checked:
		interface.last_checked = int(last_checked)

	stability_policy = root.getAttribute('stability-policy')
	if stability_policy:
		interface.set_stability_policy(stability_levels[str(stability_policy)])

	for item in root.childNodes:
		if item.uri != XMLNS_IFACE: continue
		if item.name == 'implementation':
			id = item.getAttribute('id')
			assert id is not None
			if id.startswith('/'):
				impl = interface.get_impl(id)
			else:
				assert '=' in id
				impl = interface.get_impl(id)

			user_stability = item.getAttribute('user-stability')
			if user_stability:
				impl.user_stability = stability_levels[str(user_stability)]
		elif item.name == 'feed':
			feed_src = item.getAttribute('src')
			if not feed_src:
				raise InvalidInterface('Missing "src" attribute in <feed>')
			interface.feeds.append(Feed(feed_src, item.getAttribute('arch'), True))

def check_readable(interface_uri, source):
	"""Returns the modified time in 'source'. If syntax is incorrect,
	throws an exception."""
	tmp = Interface(interface_uri)
	try:
		update(tmp, source)
	except InvalidInterface, ex:
		raise InvalidInterface("Error loading interface:\n"
					"Interface URI: %s\n"
					"Local file: %s\n%s" %
					(interface_uri, source, ex))
	return tmp.last_modified

def parse_time(t):
	try:
		return long(t)
	except Exception, ex:
		raise InvalidInterface("Date '%s' not in correct format (should be integer number "
					"of seconds since Unix epoch)\n%s" % (t, ex))

def _check_canonical_name(interface, source, root):
	"Ensure the uri= attribute in the interface file matches the interface we are trying to load"
	canonical_name = root.getAttribute('uri')
	if not canonical_name:
		raise InvalidInterface("<interface> uri attribute missing in " + source)
	if canonical_name != interface.uri:
		raise InvalidInterface("<interface> uri attribute is '%s', but accessed as '%s'\n(%s)" %
				(canonical_name, interface.uri, source))

def update(interface, source, local = False):
	"""local - use file mtime for last-modified, and uri attribute is ignored"""
	assert isinstance(interface, Interface)

	try:
		root = qdom.parse(file(source))
	except Exception, ex:
		raise InvalidInterface("Invalid XML", ex)

	if not local:
		_check_canonical_name(interface, source, root)
		time_str = root.getAttribute('last-modified')
		if not time_str:
			raise InvalidInterface("Missing last-modified attribute on root element.")
		interface.last_modified = parse_time(time_str)
	main = root.getAttribute('main')
	if main:
		interface.main = main

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
		elif x.name == 'source':
			source_interface = x.getAttribute('interface')
			if source_interface:
				interface.sources.append(Source(source_interface))
			else:
				raise InvalidInterface("Missing interface attribute on <source>")
		elif x.name == 'feed-for':
			feed_iface = x.getAttribute('interface')
			if not feed_iface:
				raise InvalidInterface('Missing "interface" attribute in <feed-for>')
			interface.feed_for[feed_iface] = True
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

			item_attrs = group_attrs.merge(item)

			for child in item.childNodes:
				if child.uri != XMLNS_IFACE: continue
				if child.name == 'requires':
					dep = Dependency(child.getAttribute('interface'))
					process_depends(dep, child)
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

		version = item_attrs.version
		if not version:
			raise InvalidInterface("Missing version attribute")
		impl.version = map(int, version.split('.'))

		impl.main = item_attrs.main

		if item_attrs.released:
			impl.released = item_attrs.released

		size = item.getAttribute('size')
		if size:
			impl.size = long(size)
		impl.arch = item_attrs.arch
		try:
			stability = stability_levels[str(item_attrs.stability)]
		except KeyError:
			stab = str(item_attrs.stability)
			if stab != stab.lower():
				raise InvalidInterface('Stability "%s" invalid - use lower case!' % item_attrs.stability)
			raise InvalidInterface('Stability "%s" invalid' % item_attrs.stability)
		if stability >= preferred:
			raise InvalidInterface("Upstream can't set stability to preferred!")
		impl.upstream_stability = stability

		impl.dependencies.update(depends)

		for elem in item.childNodes:
			if elem.uri == XMLNS_IFACE and elem.name == 'archive':
				url = elem.getAttribute('href')
				if not url:
					raise InvalidInterface("Missing href attribute on <archive>")
				size = elem.getAttribute('size')
				if not size:
					raise InvalidInterface("Missing size attribute on <archive>")
				impl.add_download_source(url = url, size = long(size),
						extract = elem.getAttribute('extract'))

	process_group(root,
		Attrs(stability = testing,
		      main = root.getAttribute('main') or None),
		{})
