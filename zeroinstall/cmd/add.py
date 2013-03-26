"""
The B{0install add} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall import _
from zeroinstall.cmd import UsageError, select
from zeroinstall.injector import model, requirements

syntax = "PET-NAME INTERFACE"

def add_options(parser):
	select.add_options(parser)

def handle(config, options, args):
	"""@type args: [str]"""
	if len(args) != 2:
		raise UsageError()

	pet_name = args[0]
	iface_uri = model.canonical_iface_uri(args[1])

	sels = select.get_selections(config, options, iface_uri, select_only = False, download_only = True, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	root_feed = config.iface_cache.get_feed(iface_uri)
	if root_feed:
		target = root_feed.get_replaced_by()
		if target is not None:
			print(_("Warning: interface {old} has been replaced by {new}".format(old = iface_uri, new = target)))

	r = requirements.Requirements(iface_uri)
	r.parse_options(options)

	app = config.app_mgr.create_app(pet_name, r)
	app.set_selections(sels)
	app.integrate_shell(pet_name)

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if cword != 1: return
	completion.expand_interfaces()
