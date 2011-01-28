"""
The B{0install list-feeds} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model

syntax = "URI"

def add_options(parser):
	pass

def handle(config, options, args):
	if len(args) != 1: raise UsageError()
	uri = model.canonical_iface_uri(args[0])
	iface = config.iface_cache.get_interface(uri)

	if iface.extra_feeds:
		for f in iface.extra_feeds:
			print f.uri
	else:
		print _("(no feeds)")
