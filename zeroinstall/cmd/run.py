"""
The B{0install run} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys

from zeroinstall import _
from zeroinstall.cmd import UsageError, select
from zeroinstall.injector import model

syntax = "URI [ARGS]"

def add_options(parser):
	select.add_generic_select_options(parser)
	parser.add_option("-m", "--main", help=_("name of the file to execute"))
	parser.add_option("-w", "--wrapper", help=_("execute program using a debugger, etc"), metavar='COMMAND')
	parser.disable_interspersed_args()

def handle(config, options, args):
	"""@type config: L{zeroinstall.injector.config.Config}
	@type args: [str]"""
	if len(args) < 1:
		raise UsageError()

	prog_args = args[1:]

	def test_callback(sels):
		from zeroinstall.injector import run
		return run.test_selections(sels, prog_args,
					     False,	# dry-run
					     options.main)

	app = config.app_mgr.lookup_app(args[0], missing_ok = True)
	if app is not None:
		sels = app.get_selections(may_update = True, use_gui = options.gui)
		r = app.get_requirements()
		do_select = r.parse_update_options(options) or options.refresh
		iface_uri = sels.interface
	else:
		iface_uri = model.canonical_iface_uri(args[0])
		r = None
		do_select = True

	if do_select or options.gui:
		sels = select.get_selections(config, options, iface_uri,
					select_only = False, download_only = False,
					test_callback = test_callback,
					requirements = r)
		if not sels:
			sys.exit(1)	# Aborted by user

	from zeroinstall.injector import run
	run.execute_selections(sels, prog_args, dry_run = options.dry_run, main = options.main, wrapper = options.wrapper, stores = config.stores)

def complete(completion, args, cword):
	"""@type completion: L{zeroinstall.cmd._Completion}
	@type args: [str]
	@type cword: int"""
	if cword == 0:
		select.complete(completion, args, cword)
	else:
		completion.expand_files()
