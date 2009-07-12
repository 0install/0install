"""
Save per-interface configuration information.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
from xml.dom import minidom, XMLNS_NAMESPACE

from zeroinstall.support import basedir

from zeroinstall.injector.model import escape
from zeroinstall.injector.namespaces import config_site, config_prog, XMLNS_IFACE
from zeroinstall.injector.iface_cache import iface_cache

def _add_impl(parent, impl):
	if impl.user_stability:
		doc = parent.ownerDocument
		node = doc.createElementNS(XMLNS_IFACE, 'implementation')
		parent.appendChild(node)
		node.setAttribute('user-stability', str(impl.user_stability))
		node.setAttribute('id', impl.id)

def save_feed(feed):
	# This is wrong. Feed and interface settings should be saved in separate files.
	save_interface(iface_cache.get_interface(feed.url))

def save_interface(interface):
	user_overrides = basedir.save_config_path(config_site, config_prog, 'user_overrides')

	impl = minidom.getDOMImplementation()
	doc = impl.createDocument(XMLNS_IFACE, 'interface-preferences', None)

	root = doc.documentElement
	root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns', XMLNS_IFACE)
	root.setAttribute('uri', interface.uri)

	if interface.stability_policy:
		root.setAttribute('stability-policy', str(interface.stability_policy))

	if interface.last_checked:
		root.setAttribute('last-checked', str(interface.last_checked))

	impls = interface.implementations.values()
	impls.sort()
	for impl in impls:
		_add_impl(root, impl)
	
	for feed in interface.extra_feeds:
		if feed.user_override:
			elem = doc.createElementNS(XMLNS_IFACE, 'feed')
			root.appendChild(elem)
			elem.setAttribute('src', feed.uri)
			if feed.arch:
				elem.setAttribute('arch', feed.arch)

	import tempfile
	tmp_fd, tmp_name = tempfile.mkstemp(dir = user_overrides)
	try:
		tmp_file = os.fdopen(tmp_fd, 'w')
		doc.writexml(tmp_file, addindent = " ", newl = '\n')
		tmp_file.close()
		path = os.path.join(user_overrides, escape(interface.uri))
		os.rename(tmp_name, path)
	except:
		os.unlink(tmp_name)
		raise
