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

	app = config.app_mgr.lookup_app(args[0], missing_ok = True)
	if app is not None:
		sels = app.get_selections()

		r = app.get_requirements()
		do_select = r.parse_update_options(options)
		iface_uri = sels.interface
	else:
		iface_uri = model.canonical_iface_uri(args[0])
		do_select = True

	if do_select or options.gui:
		sels = select.get_selections(config, options, iface_uri,
					select_only = False, download_only = True, test_callback = None)
		if not sels:
			sys.exit(1)	# Aborted by user
	else:
		dl = app.download_selections(sels)
		if dl:
			tasks.wait_for_blocker(dl)
			tasks.check(dl)

	if options.xml:
		select.show_xml(sels)
	if options.show:
		select.show_human(sels, config.stores)
		if app is not None and do_select:
			print(_("(use '0install update' to save the new parameters)"))
