"""
Save per-interface and per-feed configuration information.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from xml.dom import minidom, XMLNS_NAMESPACE

from zeroinstall import support
from zeroinstall.support import basedir

from zeroinstall.injector import model
from zeroinstall.injector.namespaces import config_site, config_prog, XMLNS_IFACE

def _atomic_save(doc, parent, uri):
	"""@type parent: str
	@type uri: str"""
	import tempfile
	tmp_fd, tmp_name = tempfile.mkstemp(dir = parent)
	try:
		tmp_file = os.fdopen(tmp_fd, 'w')
		doc.writexml(tmp_file, addindent = " ", newl = '\n')
		tmp_file.close()
		path = os.path.join(parent, model._pretty_escape(uri))
		support.portable_rename(tmp_name, path)
	except:
		os.unlink(tmp_name)
		raise

def save_interface(interface):
	"""@type interface: L{zeroinstall.injector.model.Interface}"""
	user_overrides = basedir.save_config_path(config_site, config_prog, 'interfaces')

	impl = minidom.getDOMImplementation()
	doc = impl.createDocument(XMLNS_IFACE, 'interface-preferences', None)

	root = doc.documentElement
	root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns', XMLNS_IFACE)
	root.setAttribute('uri', interface.uri)

	if interface.stability_policy:
		root.setAttribute('stability-policy', str(interface.stability_policy))

	for feed in interface.extra_feeds:
		if feed.user_override:
			elem = doc.createElementNS(XMLNS_IFACE, 'feed')
			root.appendChild(elem)
			elem.setAttribute('src', feed.uri)
			if feed.arch:
				elem.setAttribute('arch', feed.arch)
			if feed.site_package:
				elem.setAttribute('is-site-package', 'True')

	_atomic_save(doc, user_overrides, interface.uri)
