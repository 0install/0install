from xml.dom import Node, minidom
import sys

import basedir
from namespaces import *
from model import *

def get_singleton_text(parent, ns, localName):
	names = parent.getElementsByTagNameNS(ns, localName)
	if not names:
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
	cached = basedir.load_first_config(config_site, config_prog,
					   'interfaces', escape(interface.uri))
	if not cached: return False

	update(interface, cached, trusted = True)
	return True

def update_from_network(interface):
	print "Updating '%s' from network" % (interface.name or interface.uri)
	if not os.path.exists(interface.uri) and interface.uri.startswith('/uri/0install/'):
		site = interface.uri[len('/uri/0install/'):]
		site = site[:site.index('/')]
		assert '/' not in site
		print "Refreshing", site
		os.spawnlp(os.P_WAIT, '0refresh', '0refresh', site)
	update(interface, interface.uri)
	interface.uptodate = True
	import writer
	writer.save_interface(interface)

def update(interface, source, trusted = False):
	assert isinstance(interface, Interface)

	doc = minidom.parse(source)

	root = doc.documentElement
	interface.name = get_singleton_text(root, XMLNS_IFACE, 'name')
	interface.description = get_singleton_text(root, XMLNS_IFACE, 'description')
	interface.summary = get_singleton_text(root, XMLNS_IFACE, 'summary')

	if not trusted:
		canonical_name = root.getAttribute('uri')
		#if not canonical_name:
		#	raise Exception("<interface> uri attribute missing in " + source)
		if canonical_name != source:
			print >>sys.stderr, \
				"WARNING: <interface> uri attribute is '%s', but accessed as '%s'" % \
					(canonical_name, source)

	if trusted:
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
				if trusted:
					user_stability = item.getAttribute('user_stability')
					if user_stability:
						impl.user_stability = stability_levels[str(user_stability)]
				impl.dependencies.update(depends)

	process_group(root, Attrs(testing), {})
