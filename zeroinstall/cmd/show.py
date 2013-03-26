"""
The B{0install show} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os

from zeroinstall import _, SafeException
from zeroinstall.cmd import select, UsageError
from zeroinstall.injector import qdom, selections

syntax = "APP | SELECTIONS"

def add_options(parser):
	parser.add_option("-r", "--root-uri", help=_("display just the root interface URI"), action='store_true')
	parser.add_option("", "--xml", help=_("print selections as XML"), action='store_true')

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()

	app = config.app_mgr.lookup_app(args[0], missing_ok = True)
	if app is not None:
		sels = app.get_selections()

		r = app.get_requirements()

		if r.extra_restrictions and not options.xml:
			print("User-provided restrictions in force:")
			for uri, expr in r.extra_restrictions.items():
				print("  {uri}: {expr}".format(uri = uri, expr = expr))
			print()
	elif os.path.exists(args[0]):
		with open(args[0], 'rb') as stream:
			sels = selections.Selections(qdom.parse(stream))
	else:
		raise SafeException(_("Neither an app nor a file: '%s'") % args[0])

	if options.root_uri:
		print(sels.interface)
	elif options.xml:
		select.show_xml(sels)
	else:
		select.show_human(sels, config.stores)

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if len(args) != 1: return
	completion.expand_apps()
	completion.expand_files()
