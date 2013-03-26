"""
The B{0install list-feeds} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, reader

syntax = "URI"

def add_options(parser):
	pass

def handle(config, options, args):
	"""@type args: [str]"""
	if len(args) != 1: raise UsageError()
	uri = model.canonical_iface_uri(args[0])
	iface = config.iface_cache.get_interface(uri)

	if iface.extra_feeds:
		for f in iface.extra_feeds:
			print(f.uri)
	else:
		print(_("(no feeds)"))

# Lists only interfaces with feeds.
# Note: this is also used by remove-feed.
def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if len(args) != 1: return
	iface_cache = completion.config.iface_cache
	for uri in iface_cache.list_all_interfaces():
		dummy = model.Interface(uri)
		reader.update_user_overrides(dummy)
		if dummy.extra_feeds:
			completion.add_filtered(uri)
