"""
The B{0install select} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os, sys
import logging

from zeroinstall import _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, selections, requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.support import tasks

syntax = "URI"

def add_generic_select_options(parser):
	"""All options for selecting."""
	parser.add_option("", "--before", help=_("choose a version before this"), metavar='VERSION')
	parser.add_option("", "--command", help=_("command to select"), metavar='COMMAND')
	parser.add_option("", "--cpu", help=_("target CPU type"), metavar='CPU')
	parser.add_option("", "--message", help=_("message to display when interacting with user"))
	parser.add_option("", "--not-before", help=_("minimum version to choose"), metavar='VERSION')
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')
	parser.add_option("", "--os", help=_("target operation system type"), metavar='OS')
	parser.add_option("-r", "--refresh", help=_("refresh all used interfaces"), action='store_true')
	parser.add_option("-s", "--source", help=_("select source code"), action='store_true')

def add_options(parser):
	"""Options for 'select' and 'download' (but not 'run')"""
	add_generic_select_options(parser)
	parser.add_option("", "--xml", help=_("write selected versions as XML"), action='store_true')

def get_selections(config, options, iface_uri, select_only, download_only, test_callback):
	"""Get selections for iface_uri, according to the options passed.
	Will switch to GUI mode if necessary.
	@param options: options from OptionParser
	@param iface_uri: canonical URI of the interface
	@param select_only: return immediately even if the selected versions aren't cached
	@param download_only: wait for stale feeds, and display GUI button as Download, not Run
	@return: the selected versions, or None if the user cancels
	@rtype: L{selections.Selections} | None
	"""
	if options.offline:
		config.network_use = model.network_offline

	iface_cache = config.iface_cache

	# Try to load it as a feed. If it is a feed, it'll get cached. If not, it's a
	# selections document and we return immediately.
	maybe_selections = iface_cache.get_feed(iface_uri, selections_ok = True)
	if isinstance(maybe_selections, selections.Selections):
		if not select_only:
			blocker = maybe_selections.download_missing(config)
			if blocker:
				logging.info(_("Waiting for selected implementations to be downloaded..."))
				tasks.wait_for_blocker(blocker)
		return maybe_selections

	r = requirements.Requirements(iface_uri)
	r.parse_options(options)

	return get_selections_for(r, config, options, select_only, download_only, test_callback)

def get_selections_for(requirements, config, options, select_only, download_only, test_callback):
	"""Get selections for given requirements.
	@since: 1.9"""
	if options.offline:
		config.network_use = model.network_offline

	iface_cache = config.iface_cache

	driver = Driver(config = config, requirements = requirements)

	# Note that need_download() triggers a solve
	if options.refresh or options.gui:
		# We could run immediately, but the user asked us not to
		can_run_immediately = False
	else:
		if select_only:
			# --select-only: we only care that we've made a selection, not that we've cached the implementations
			driver.need_download()
			can_run_immediately = driver.solver.ready
		else:
			can_run_immediately = not driver.need_download()

		stale_feeds = [feed for feed in driver.solver.feeds_used if
				not feed.startswith('distribution:') and	# Ignore (memory-only) PackageKit feeds
				iface_cache.is_stale(feed, config.freshness)]

		if download_only and stale_feeds:
			can_run_immediately = False

	if can_run_immediately:
		if stale_feeds:
			if config.network_use == model.network_offline:
				logging.debug(_("No doing background update because we are in off-line mode."))
			else:
				# There are feeds we should update, but we can run without them.
				# Do the update in the background while the program is running.
				from zeroinstall.injector import background
				background.spawn_background_update(driver, options.verbose)
		return driver.solver.selections

	# If the user didn't say whether to use the GUI, choose for them.
	if options.gui is None and os.environ.get('DISPLAY', None):
		options.gui = True
		# If we need to download anything, we might as well
		# refresh all the feeds first.
		options.refresh = True
		logging.info(_("Switching to GUI mode... (use --console to disable)"))

	if options.gui:
		gui_args = driver.requirements.get_as_options()
		if download_only:
			# Just changes the button's label
			gui_args.append('--download-only')
		if options.refresh:
			gui_args.append('--refresh')
		if options.verbose:
			gui_args.insert(0, '--verbose')
			if options.verbose > 1:
				gui_args.insert(0, '--verbose')
		if options.with_store:
			for x in options.with_store:
				gui_args += ['--with-store', x]
		if select_only:
			gui_args.append('--select-only')

		from zeroinstall import helpers
		sels = helpers.get_selections_gui(requirements.interface_uri, gui_args, test_callback)

		if not sels:
			return None		# Aborted
	else:
		# Note: --download-only also makes us stop and download stale feeds first.
		downloaded = driver.solve_and_download_impls(refresh = options.refresh or download_only or False,
							     select_only = select_only)
		if downloaded:
			tasks.wait_for_blocker(downloaded)
		sels = driver.solver.selections

	return sels

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
		sels = get_selections(config, options, iface_uri,
					select_only = True, download_only = False, test_callback = None)
		if not sels:
			sys.exit(1)	# Aborted by user

	if options.xml:
		show_xml(sels)
	else:
		show_human(sels, config.stores)
		if app is not None and do_select:
			print(_("(use '0install update' to save the new parameters)"))

def show_xml(sels):
	doc = sels.toDOM()
	doc.writexml(sys.stdout)
	sys.stdout.write('\n')

def show_human(sels, stores):
	done = set()	# detect cycles
	def print_node(uri, commands, indent):
		if uri in done: return
		done.add(uri)
		impl = sels.selections.get(uri, None)
		print(indent + "- URI:", uri)
		if impl:
			print(indent + "  Version:", impl.version)
			#print indent + "  Command:", command
			if impl.id.startswith('package:'):
				path = "(" + impl.id + ")"
			else:
				path = impl.get_path(stores, missing_ok = True) or _("(not cached)")
			print(indent + "  Path:", path)
			indent += "  "

			deps = impl.dependencies
			for c in commands:
				deps += impl.get_command(c).requires
			for child in deps:
				print_node(child.interface, child.get_required_commands(), indent)
		else:
			print(indent + "  No selected version")


	if sels.command:
		print_node(sels.interface, [sels.command], "")
	else:
		print_node(sels.interface, [], "")
