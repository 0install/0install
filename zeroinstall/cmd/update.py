"""
The B{0install download} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from optparse import OptionParser
import os, sys
import logging

from zeroinstall import cmd, SafeException, _
from zeroinstall.injector import model
from zeroinstall.cmd import UsageError, select

syntax = "URI"

add_options = select.add_generic_select_options

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()

	assert not options.offline

	iface_uri = model.canonical_iface_uri(args[0])

	old_gui = options.gui

	# Select once in offline console mode to get the old values
	options.offline = True
	options.gui = False
	options.refresh = False

	try:
		old_sels = select.get_selections(config, options, iface_uri,
					select_only = True, download_only = False, test_callback = None)
	except SafeException, ex:
		old_selections = {}
	else:
		if old_sels is None:
			old_selections = {}
		else:
			old_selections = old_sels.selections

	# Download in online mode to get the new values
	options.offline = False
	options.gui = old_gui
	options.refresh = True

	sels = select.get_selections(config, options, iface_uri,
				select_only = False, download_only = True, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	changes = False

	for iface, old_sel in old_selections.iteritems():
		new_sel = sels.selections.get(iface, None)
		if new_sel is None:
			print _("No longer used: %s") % iface
			changes = True
		elif old_sel.version != new_sel.version:
			print _("%s: %s -> %s") % (iface, old_sel.version, new_sel.version)
			changes = True

	for iface, new_sel in sels.selections.iteritems():
		if iface not in old_selections:
			print _("%s: new -> %s") % (iface, new_sel.version)
			changes = True

	if not changes:
		print _("No updates found.")
