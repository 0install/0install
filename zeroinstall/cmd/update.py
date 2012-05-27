"""
The B{0install download} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall import SafeException, _
from zeroinstall.injector import model, requirements
from zeroinstall.cmd import UsageError, select

syntax = "URI"

add_options = select.add_generic_select_options

def handle(config, options, args):
	if len(args) != 1:
		raise UsageError()

	assert not options.offline

	old_gui = options.gui

	app = config.app_mgr.lookup_app(args[0], missing_ok = True)
	if app is not None:
		old_sels = app.get_selections()
		old_selections = old_sels.selections
		iface_uri = old_sels.interface
		r = app.get_requirements()
		r.parse_update_options(options)
	else:
		iface_uri = model.canonical_iface_uri(args[0])

		r = requirements.Requirements(iface_uri)
		r.parse_options(options)

		# Select once in offline console mode to get the old values
		options.offline = True
		options.gui = False
		options.refresh = False

		try:
			old_sels = select.get_selections_for(r, config, options,
						select_only = True, download_only = False, test_callback = None)
		except SafeException:
			old_selections = {}
		else:
			if old_sels is None:
				old_selections = {}
			else:
				old_selections = old_sels.selections

	# Download in online mode to get the new values
	config.network_use = model.network_full
	options.offline = False
	options.gui = old_gui
	options.refresh = True

	sels = select.get_selections_for(r, config, options,
				select_only = False, download_only = True, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	root_feed = config.iface_cache.get_feed(iface_uri)
	if root_feed:
		target = root_feed.get_replaced_by()
		if target is not None:
			print(_("Warning: interface {old} has been replaced by {new}".format(old = iface_uri, new = target)))

	from zeroinstall.cmd import whatchanged
	changes = whatchanged.show_changes(old_selections, sels.selections)

	root_sel = sels[iface_uri]
	root_iface = config.iface_cache.get_interface(iface_uri)
	latest = max((impl.version, impl) for impl in root_iface.implementations.values())[1]
	if latest.version > model.parse_version(sels[iface_uri].version):
		print(_("A later version ({name} {latest}) exists but was not selected. Using {version} instead.").format(
				latest = latest.get_version(),
				name = root_iface.get_name(),
				version = root_sel.version))
		if not config.help_with_testing and latest.get_stability() < model.stable:
			print(_('To select "testing" versions, use:\n0install config help_with_testing True'))
	elif not changes:
		from zeroinstall.support import xmltools

		# No obvious changes, but check for more subtle updates.
		if xmltools.nodes_equal(sels.toDOM(), old_sels.toDOM()):
			print(_("No updates found. Continuing with version {version}.").format(version = root_sel.version))
		else:
			changes = True
			print(_("Updates to metadata found, but no change to version ({version}).").format(version = root_sel.version))

	if app is not None:
		if changes:
			app.set_selections(sels)
		app.set_requirements(r)
