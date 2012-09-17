"""
The B{0install man} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys, os

from zeroinstall import support, logger

syntax = "NAME"

def add_options(parser):
	pass

def handle(config, options, args):
	if len(args) != 1 or not _0install_man(config, args[0]):
		logger.debug("Not a 0install alias or app-script, so passing through to system man command: %r", args)
		os.execlp('man', 'man', *args)

def _0install_man(config, command):
	from zeroinstall import apps, alias, helpers

	path = support.find_in_path(command)
	if not path:
		return None

	with open(path, 'rt') as stream:
		app_info = apps.parse_script_header(stream)
		if app_info:
			app = config.app_mgr.lookup_app(app_info.name)
			sels = app.get_selections()
			main = None
		else:
			alias_info = alias.parse_script_header(stream)
			if alias_info is None:
				return None
			sels = helpers.ensure_cached(alias_info.uri, alias_info.command, config = config)
			if not sels:
				# Cancelled by user
				sys.exit(1)
			main = alias_info.main

	helpers.exec_man(config.stores, sels, main, fallback_name = command)
	assert 0
