"""
The B{0install whatchanged} command-line interface.
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os

from zeroinstall import _, SafeException
from zeroinstall.cmd import UsageError

syntax = "APP-NAME"

def add_options(parser):
	parser.add_option("", "--full", help=_("show diff of the XML"), action='store_true')

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()

	name = args[0]
	app = config.app_mgr.lookup_app(name, missing_ok = False)
	history = app.get_history()

	if not history:
		raise SafeException(_("Invalid application: no selections found! Try '0install destroy {name}'").format(name = name))

	import time

	last_checked = app.get_last_checked()
	if last_checked is not None:
		print(_("Last checked    : {date}").format(date = time.ctime(last_checked)))

	last_attempt = app.get_last_check_attempt()
	if last_attempt is not None:
		print(_("Last attempted update: {date}").format(date = time.ctime(last_attempt)))

	print(_("Last update     : {date}").format(date = history[0]))
	current_sels = app.get_selections(snapshot_date = history[0])

	if len(history) == 1:
		print(_("No previous history to compare against."))
		print(_("Use '0install select {name}' to see the current selections.").format(name = name))
		return

	print(_("Previous update : {date}").format(date = history[1]))

	def get_selections_path(date):
		return os.path.join(app.path, 'selections-{date}.xml'.format(date = date))

	print()

	if options.full:
		import difflib, sys
		def load_lines(date):
			with open(get_selections_path(date), 'r') as stream:
				return stream.readlines()
		old_lines = load_lines(history[1])
		new_lines = load_lines(history[0])
		for line in difflib.unified_diff(old_lines, new_lines, fromfile = history[1], tofile = history[0]):
			sys.stdout.write(line)
	else:
		changes = show_changes(app.get_selections(snapshot_date = history[1]).selections, current_sels.selections)
		if not changes:
			print(_("No changes to versions (use --full to see all changes)."))

	print()
	print(_("To run using the previous selections, use:"))
	print("0install run {path}".format(path = get_selections_path(history[1])))

def show_changes(old_selections, new_selections):
	changes = False

	for iface, old_sel in old_selections.iteritems():
		new_sel = new_selections.get(iface, None)
		if new_sel is None:
			print(_("No longer used: %s") % iface)
			changes = True
		elif old_sel.version != new_sel.version:
			print(_("%s: %s -> %s") % (iface, old_sel.version, new_sel.version))
			changes = True

	for iface, new_sel in new_selections.iteritems():
		if iface not in old_selections:
			print(_("%s: new -> %s") % (iface, new_sel.version))
			changes = True
	
	return changes
