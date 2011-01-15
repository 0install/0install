"""
The B{0install download} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys

from zeroinstall import _
from zeroinstall.cmd import UsageError, select
from zeroinstall.injector import model

syntax = "URI"

def add_options(parser):
	select.add_options(parser)
	parser.add_option("", "--show", help=_("show where components are installed"), action='store_true')

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()
	iface_uri = model.canonical_iface_uri(args[0])

	sels = select.get_selections(config, options, iface_uri,
				select_only = False, download_only = True, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	if options.xml:
		select.show_xml(sels)
	if options.show:
		select.show_human(sels, config.stores)
