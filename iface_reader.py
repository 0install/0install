from xml.dom import Node, minidom

from namespaces import XMLNS_IFACE
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
			new.path = os.path.join(self.path, item.getAttribute('path'))
		for x in ('arch', 'stability', 'version'):
			if item.hasAttribute(x):
				setattr(new, x, item.getAttribute(x))
		return new

def process_depends(dependency, item):
	print item

def update(interface):
	assert isinstance(interface, Interface)

	doc = minidom.parse(interface.uri)

	root = doc.documentElement
	interface.name = get_singleton_text(root, XMLNS_IFACE, 'name')
	interface.description = get_singleton_text(root, XMLNS_IFACE, 'description')
	interface.summary = get_singleton_text(root, XMLNS_IFACE, 'summary')

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
				size = item.getAttribute('size')
				if size: size = long(size)
				else: size = None
				impl = interface.get_impl(item_attrs.path,
							  item_attrs.version,
							  size)
				impl.dependencies.update(depends)
				impl.arch = item_attrs.arch
				impl.may_set_stability(item_attrs.stability)

	process_group(root, Attrs('testing'), {})
