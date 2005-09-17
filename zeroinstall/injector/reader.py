from xml.dom import Node, minidom
import sys
import shutil
import time
from logging import debug, warn

import basedir
from namespaces import *
from model import *

class InvalidInterface(SafeException):
	def __init__(self, message, ex = None):
		if ex:
			message += "\n\n(exact error: %s)" % ex
		SafeException.__init__(self, message)

def get_singleton_text(parent, ns, localName):
	names = parent.getElementsByTagNameNS(ns, localName)
	if not names:
		raise InvalidInterface('No <%s> element in <%s>' % (localName, parent.localName))
	if len(names) > 1:
		raise InvalidInterface('Multiple <%s> elements in <%s>' % (localName, parent.localName))
	text = ''
	for x in names[0].childNodes:
		if x.nodeType == Node.TEXT_NODE:
			text += x.data
	return text.strip()

class Attrs(object):
	__slots__ = ['version', 'released', 'arch', 'stability', 'main']
	def __init__(self, **kwargs):
		for x in self.__slots__:
			setattr(self, x, kwargs.get(x, None))
	
	def merge(self, item):
		new = Attrs()
		for x in self.__slots__:
			if item.hasAttribute(x):
				value = item.getAttribute(x)
			else:
				value = getattr(self, x)
			setattr(new, x, value)
		return new

def process_depends(dependency, item):
	for e in item.getElementsByTagNameNS(XMLNS_IFACE, 'environment'):
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

	return bool(cached)

def update_user_overrides(interface):
	user = basedir.load_first_config(config_site, config_prog,
					   'user_overrides', escape(interface.uri))
	if not user:
		return

	doc = minidom.parse(user)
	root = doc.documentElement

	last_checked = root.getAttribute('last-checked')
	if last_checked:
		interface.last_checked = int(last_checked)

	stability_policy = root.getAttribute('stability-policy')
	if stability_policy:
		interface.set_stability_policy(stability_levels[str(stability_policy)])

	for item in root.getElementsByTagNameNS(XMLNS_IFACE, 'implementation'):
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

	for feed in root.getElementsByTagNameNS(XMLNS_IFACE, 'feed'):
		feed_src = feed.getAttribute('src')
		if not feed_src:
			raise InvalidInterface('Missing "src" attribute in <feed>')
		interface.feeds.append(feed_src)

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
		doc = minidom.parse(source)
	except Exception, ex:
		raise InvalidInterface("Invalid XML", ex)

	root = doc.documentElement

	interface.name = interface.name or get_singleton_text(root, XMLNS_IFACE, 'name')
	interface.description = interface.description or get_singleton_text(root, XMLNS_IFACE, 'description')
	interface.summary = interface.summary or get_singleton_text(root, XMLNS_IFACE, 'summary')

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
	
	for source in root.getElementsByTagNameNS(XMLNS_IFACE, 'source'):
		source_interface = source.getAttribute('interface')
		if source_interface:
			interface.sources.append(Source(source_interface))
		else:
			raise InvalidInterface("Missing interface attribute on <source>")

	def process_group(group, group_attrs, base_depends):
		for item in group.childNodes:
			depends = base_depends.copy()
			if item.namespaceURI != XMLNS_IFACE:
				continue

			item_attrs = group_attrs.merge(item)

			for dep_elem in item.getElementsByTagNameNS(XMLNS_IFACE, 'requires'):
				dep = Dependency(dep_elem.getAttribute('interface'))
				process_depends(dep, dep_elem)
				depends[dep.interface] = dep

			if item.localName == 'group':
				process_group(item, item_attrs, depends)
			elif item.localName == 'implementation':
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
			raise InvalidInterface('Stability "%s" invalid' % item_attrs.stability)
		if stability >= preferred:
			raise InvalidInterface("Upstream can't set stability to preferred!")
		impl.upstream_stability = stability

		impl.dependencies.update(depends)

		for elem in item.getElementsByTagNameNS(XMLNS_IFACE, 'archive'):
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
