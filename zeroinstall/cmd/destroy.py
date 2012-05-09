"""
The B{0install destroy} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall.cmd import UsageError

syntax = "PET-NAME"

def add_options(parser):
	pass

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()

	pet_name = args[0]

	app = config.app_mgr.lookup_app(pet_name)
	app.destroy()
