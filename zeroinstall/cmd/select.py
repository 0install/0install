"""
The B{0install select} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall import _, logger
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, selections
from zeroinstall.injector.requirements import Requirements
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
	parser.add_option("", "--version", help=_("specify version constraint (e.g. '3' or '3..')"), metavar='RANGE')
	parser.add_option("", "--version-for", help=_("set version constraints for a specific interface"),
			nargs=2, metavar='URI RANGE', action='append')

def add_options(parser):
	"""Options for 'select' and 'download' (but not 'run')"""
	add_generic_select_options(parser)
	parser.add_option("", "--xml", help=_("write selected versions as XML"), action='store_true')

def get_selections(config, options, iface_uri, select_only, download_only, test_callback, requirements = None):
	"""Get selections for iface_uri, according to the options passed.
	Will switch to GUI mode if necessary.
	@type config: L{zeroinstall.injector.config.Config}
	@param options: options from OptionParser
	@param iface_uri: canonical URI of the interface
	@type iface_uri: str
	@param select_only: return immediately even if the selected versions aren't cached
	@type select_only: bool
	@param download_only: wait for stale feeds, and display GUI button as Download, not Run
	@type download_only: bool
	@param requirements: requirements to use; if None, requirements come from options (since 1.15)
	@type requirements: Requirements
	@return: the selected versions, or None if the user cancels
	@rtype: L{selections.Selections} | None"""
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
				logger.info(_("Waiting for selected implementations to be downloaded..."))
				tasks.wait_for_blocker(blocker)
		return maybe_selections

	if requirements is None:
		requirements = Requirements(iface_uri)
		requirements.parse_options(options)

	return get_selections_for(requirements, config, options, select_only, download_only, test_callback)

def get_selections_for(requirements, config, options, select_only, download_only, test_callback):
	"""Get selections for given requirements.
	@type requirements: L{Requirements}
	@type config: L{zeroinstall.injector.config.Config}
	@type select_only: bool
	@type download_only: bool
	@rtype: L{zeroinstall.injector.selections.Selections}
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
				logger.debug(_("No doing background update because we are in off-line mode."))
			elif options.dry_run:
				print(_("[dry-run] would check for updates in the background"))
			else:
				# There are feeds we should update, but we can run without them.
				# Do the update in the background while the program is running.
				from zeroinstall.injector import background
				background.spawn_background_update(driver, options.verbose)
		return driver.solver.selections

	# If we need to download anything, we might as well
	# refresh all the feeds first.
	options.refresh = True

	if options.gui != False:
		# If the user didn't say whether to use the GUI, choose for them.
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
		sels = helpers.get_selections_gui(requirements.interface_uri, gui_args, test_callback, use_gui = options.gui)

		if not sels:
			return None		# Aborted
		elif sels is helpers.DontUseGUI:
			sels = None
	else:
		sels = None

	if sels is None:
		# Note: --download-only also makes us stop and download stale feeds first.
		downloaded = driver.solve_and_download_impls(refresh = options.refresh or download_only or False,
							     select_only = select_only)
		if downloaded:
			tasks.wait_for_blocker(downloaded)
		sels = driver.solver.selections

	return sels

def handle(config, options, args):
	"""@type config: L{zeroinstall.injector.config.Config}
	@type args: [str]"""
	if len(args) == 1:
		select_only = True
		download_only = False
		arg = args[0]
	elif len(args) == 2:
		if args[0] == 'for-select':
			select_only = True
			download_only = False
		elif args[0] == 'for-download':
			select_only = False
			download_only = True
		elif args[0] == 'for-run':
			select_only = False
			download_only = False
		else:
			assert 0, args
		arg = args[1]
	else:
		raise UsageError()

	app = config.app_mgr.lookup_app(arg, missing_ok = True)
	if app is not None:
		old_sels = app.get_selections()

		requirements = app.get_requirements()
		changes = requirements.parse_update_options(options)
		iface_uri = old_sels.interface

		if requirements.extra_restrictions and not options.xml:
			print("User-provided restrictions in force:")
			for uri, expr in requirements.extra_restrictions.items():
				print("  {uri}: {expr}".format(uri = uri, expr = expr))
			print()
	else:
		iface_uri = model.canonical_iface_uri(arg)
		requirements = None
		changes = False

	sels = get_selections(config, options, iface_uri,
				select_only = select_only, download_only = download_only, test_callback = None, requirements = requirements)
	if not sels:
		# Aborted by user
		if options.xml:
			print("<?xml version='1.0'?>\n<cancelled/>")
			sys.exit(0)
		else:
			sys.exit(1)

	if options.xml:
		show_xml(sels)
	else:
		show_human(sels, config.stores)
		if app is not None:
			from zeroinstall.cmd import whatchanged
			changes = whatchanged.show_changes(old_sels.selections, sels.selections) or changes
			if changes:
				print(_("(note: use '0install update' instead to save the changes)"))

def show_xml(sels):
	"""@type sels: L{zeroinstall.injector.selections.Selections}"""
	doc = sels.toDOM()
	doc.writexml(sys.stdout)
	sys.stdout.write('\n')

def show_human(sels, stores):
	"""@type sels: L{zeroinstall.injector.selections.Selections}
	@type stores: L{zeroinstall.zerostore.Stores}"""
	done = set()	# detect cycles
	def print_node(uri, commands, indent):
		if uri in done: return
		if done: print()
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
