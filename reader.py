from xml.dom import Node, minidom
import sys
import shutil
from logging import debug

import basedir
from namespaces import *
from model import *

class InvalidInterface(Exception):
	def __init__(self, message, ex = None):
		if ex:
			message += "\n\n(exact error: %s)" % ex
		Exception.__init__(self, message)

def get_singleton_text(parent, ns, localName, user):
	names = parent.getElementsByTagNameNS(ns, localName)
	if not names:
		if user:
			return None
		raise Exception('No <%s> element in <%s>' % (localName, parent.localName))
	if len(names) > 1:
		raise Exception('Multiple <%s> elements in <%s>' % (localName, parent.localName))
	text = ''
	for x in names[0].childNodes:
		if x.nodeType == Node.TEXT_NODE:
			text += x.data
	return text.strip()

class Attrs(object):
	__slots__ = ['version', 'arch', 'path', 'stability']
	def __init__(self, stability, version = None, arch = None, path = None):
		self.version = version
		self.arch = arch
		self.path = path
		self.stability = stability
	
	def merge(self, item):
		new = Attrs(self.stability, self.version, self.arch, self.path)

		if item.hasAttribute('path'):
			if self.path:
				new.path = os.path.join(self.path, item.getAttribute('path'))
			else:
				new.path = item.getAttribute('path')
		for x in ('arch', 'stability', 'version'):
			if item.hasAttribute(x):
				setattr(new, x, item.getAttribute(x))
		return new

def process_depends(dependency, item):
	for e in item.getElementsByTagNameNS(XMLNS_IFACE, 'environment'):
		binding = EnvironmentBinding(e.getAttribute('name'),
					     insert = e.getAttribute('insert'))
		dependency.bindings.append(binding)

def update_from_cache(interface):
	"""True if cached version and user overrides loaded OK.
	False if not cached."""
	cached = basedir.load_first_config(config_site, config_prog,
					   'interfaces', escape(interface.uri))
	if not cached:
		return False

	interface.reset()
	update(interface, cached)
	update_user_overrides(interface)

	return True

def update_user_overrides(interface):
	user = basedir.load_first_config(config_site, config_prog,
					   'user_overrides', escape(interface.uri))
	
	if user:
		update(interface, user, user_overrides = True)

def check_readable(interface_uri, source):
	tmp = Interface(interface_uri)
	update(tmp, source)

def update(interface, source, user_overrides = False):
	assert isinstance(interface, Interface)

	try:
		doc = minidom.parse(source)
	except Exception, ex:
		raise InvalidInterface("Invalid XML", ex)

	root = doc.documentElement

	interface.name = interface.name or get_singleton_text(root, XMLNS_IFACE, 'name', user_overrides)
	interface.description = interface.description or get_singleton_text(root, XMLNS_IFACE, 'description', user_overrides)
	interface.summary = interface.summary or get_singleton_text(root, XMLNS_IFACE, 'summary', user_overrides)

	if not user_overrides:
		canonical_name = root.getAttribute('uri')
		if not canonical_name:
			raise Exception("<interface> uri attribute missing in " + source)
		if canonical_name != interface.uri:
			print >>sys.stderr, \
				"WARNING: <interface> uri attribute is '%s', but accessed as '%s'" % \
					(canonical_name, interface.uri)

	if user_overrides:
		stability_policy = root.getAttribute('stability_policy')
		if stability_policy:
			interface.set_stability_policy(stability_levels[str(stability_policy)])

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
				impl = interface.get_impl(item_attrs.path)

				if user_overrides:
					user_stability = item.getAttribute('user_stability')
					if user_stability:
						impl.user_stability = stability_levels[str(user_stability)]
				else:
					impl.version = map(int, item_attrs.version.split('.'))

					size = item.getAttribute('size')
					if size:
						impl.size = long(size)
					impl.arch = item_attrs.arch
					try:
						stability = stability_levels[str(item_attrs.stability)]
					except KeyError:
						raise Exception('Stability "%s" invalid' % item_attrs.stability)
					if stability >= preferred:
						raise Exception("Upstream can't set stability to preferred!")
					impl.upstream_stability = stability
				impl.dependencies.update(depends)

	process_group(root, Attrs(testing), {})
