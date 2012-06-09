"""
The B{0install add} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall.cmd import UsageError, select
from zeroinstall.injector import model, requirements

syntax = "PET-NAME INTERFACE"

def add_options(parser):
	select.add_options(parser)

def handle(config, options, args):
	if len(args) != 2:
		raise UsageError()

	pet_name = args[0]
	iface_uri = model.canonical_iface_uri(args[1])

	sels = select.get_selections(config, options, iface_uri, select_only = False, download_only = True, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	r = requirements.Requirements(iface_uri)
	r.parse_options(options)

	app = config.app_mgr.create_app(pet_name, r)
	app.set_selections(sels)
	app.integrate_shell(pet_name)
