import os
from xml.dom import minidom, XMLNS_NAMESPACE

import basedir

from namespaces import config_site, config_prog, XMLNS_IFACE

def escape(uri):
	"Convert each space to %20, etc"
	import re
	return re.sub('[^-_.a-zA-Z0-9]',
		lambda match: '%%%02x' % ord(match.group(0)),
		uri.encode('utf-8'))

def add_text(parent, name, text):
	doc = parent.ownerDocument
	element = doc.createElementNS(XMLNS_IFACE, name)
	parent.appendChild(element)
	element.appendChild(doc.createTextNode(text))

def add_impl(parent, impl):
	doc = parent.ownerDocument
	node = doc.createElementNS(XMLNS_IFACE, 'implementation')
	parent.appendChild(node)
	node.setAttribute('version', impl.get_version())
	node.setAttribute('path', impl.path)
	if impl.upstream_stability:
		node.setAttribute('stability', str(impl.upstream_stability))
	if impl.user_stability:
		node.setAttribute('user_stability', str(impl.user_stability))
	if impl.size:
		node.setAttribute('size', str(impl.size))

def save_interface(interface):
	assert interface.uptodate

	path = basedir.save_config_path(config_site, config_prog, 'interfaces')
	path = os.path.join(path, escape(interface.uri))
	print "Save to", path

	impl = minidom.getDOMImplementation()
	doc = impl.createDocument(XMLNS_IFACE, 'interface', None)

	root = doc.documentElement
	root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns', XMLNS_IFACE)

	add_text(root, 'name', interface.name)
	add_text(root, 'summary', interface.summary)
	add_text(root, 'description', interface.description)

	impls = interface.implementations.values()
	impls.sort()
	for impl in impls:
		add_impl(root, impl)

	doc.writexml(file(path + '.new', 'w'), addindent = " ", newl = '\n')
	os.rename(path + '.new', path)
