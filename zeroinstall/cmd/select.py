"""
The B{0install select} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from optparse import OptionParser
import os, sys
import logging

from zeroinstall import cmd, SafeException, _
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, autopolicy, selections, handler
from zeroinstall.injector.iface_cache import iface_cache

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

def get_selections(options, iface_uri, select_only, download_only, test_callback):
	"""Get selections for iface_uri, according to the options passed.
	Will switch to GUI mode if necessary.
	@param options: options from OptionParser
	@param iface_uri: canonical URI of the interface
	@param select_only: return immediately even if the selected versions aren't cached
	@param download_only: wait for stale feeds, and display GUI button as Download, not Run
	@return: the selected versions, or None if the user cancels
	@rtype: L{selections.Selections} | None
	"""
	root_iface = iface_cache.get_interface(iface_uri)

	if os.isatty(1):
		h = handler.ConsoleHandler()
	else:
		h = handler.Handler()

	command_name = options.command
	if command_name is None:
		command_name = 'run'
	elif command_name == '':
		command_name = None
	policy = autopolicy.AutoPolicy(iface_uri,
				handler = h,
				download_only = True,	# unused?
				src = options.source,
				command = command_name)

	if options.before or options.not_before:
		policy.solver.extra_restrictions[root_iface] = [
				model.VersionRangeRestriction(model.parse_version(options.before),
							      model.parse_version(options.not_before))]

	if options.os or options.cpu:
		from zeroinstall.injector import arch
		policy.target_arch = arch.get_architecture(options.os, options.cpu)

	if options.offline:
		policy.network_use = model.network_offline

	# Note that need_download() triggers a solve
	if options.refresh or options.gui:
		# We could run immediately, but the user asked us not to
		can_run_immediately = False
	else:
		if select_only:
			# --select-only: we only care that we've made a selection, not that we've cached the implementations
			policy.need_download()
			can_run_immediately = policy.ready
		else:
			can_run_immediately = not policy.need_download()

		stale_feeds = [feed for feed in policy.solver.feeds_used if
				not feed.startswith('distribution:') and	# Ignore (memory-only) PackageKit feeds
				policy.is_stale(iface_cache.get_feed(feed))]

		if download_only and stale_feeds:
			can_run_immediately = False

	if can_run_immediately:
		if stale_feeds:
			if policy.network_use == model.network_offline:
				logging.debug(_("No doing background update because we are in off-line mode."))
			else:
				# There are feeds we should update, but we can run without them.
				# Do the update in the background while the program is running.
				from zeroinstall.injector import background
				background.spawn_background_update(policy, options.verbose > 0)
		return policy.solver.selections

	# If the user didn't say whether to use the GUI, choose for them.
	if options.gui is None and os.environ.get('DISPLAY', None):
		options.gui = True
		# If we need to download anything, we might as well
		# refresh all the feeds first.
		options.refresh = True
		logging.info(_("Switching to GUI mode... (use --console to disable)"))

	if options.gui:
		gui_args = []
		if download_only:
			# Just changes the button's label
			gui_args.append('--download-only')
		if options.refresh:
			gui_args.append('--refresh')
		if options.not_before:
			gui_args.insert(0, options.not_before)
			gui_args.insert(0, '--not-before')
		if options.before:
			gui_args.insert(0, options.before)
			gui_args.insert(0, '--before')
		if options.source:
			gui_args.insert(0, '--source')
		if options.message:
			gui_args.insert(0, options.message)
			gui_args.insert(0, '--message')
		if options.verbose:
			gui_args.insert(0, '--verbose')
			if options.verbose > 1:
				gui_args.insert(0, '--verbose')
		if options.cpu:
			gui_args.insert(0, options.cpu)
			gui_args.insert(0, '--cpu')
		if options.os:
			gui_args.insert(0, options.os)
			gui_args.insert(0, '--os')
		if options.with_store:
			for x in options.with_store:
				gui_args += ['--with-store', x]
		if select_only:
			gui_args.append('--select-only')
		if command_name is not None:
			gui_args.append('--command')
			gui_args.append(command_name)

		from zeroinstall import helpers
		sels = helpers.get_selections_gui(iface_uri, gui_args, test_callback)

		if not sels:
			return None		# Aborted
	else:
		# Note: --download-only also makes us stop and download stale feeds first.
		downloaded = policy.solve_and_download_impls(refresh = options.refresh or download_only or False,
							     select_only = select_only)
		if downloaded:
			policy.handler.wait_for_blocker(downloaded)
		sels = selections.Selections(policy)

	return sels

def handle(options, args):
	if len(args) != 1:
		raise UsageError()
	iface_uri = model.canonical_iface_uri(args[0])

	sels = get_selections(options, iface_uri,
				select_only = True, download_only = False, test_callback = None)
	if not sels:
		sys.exit(1)	# Aborted by user

	if options.xml:
		show_xml(sels)
	else:
		show_human(sels)

def show_xml(sels):
	doc = sels.toDOM()
	doc.writexml(sys.stdout)
	sys.stdout.write('\n')

def show_human(sels):
	from zeroinstall import zerostore
	done = set()	# detect cycles
	def print_node(uri, command, indent):
		if uri in done: return
		done.add(uri)
		impl = sels.selections.get(uri, None)
		print indent + "- URI:", uri
		if impl:
			print indent + "  Version:", impl.version
			try:
				if impl.id.startswith('package:'):
					path = "(" + impl.id + ")"
				else:
					path = impl.local_path or iface_cache.stores.lookup_any(impl.digests)
			except zerostore.NotStored:
				path = "(not cached)"
			print indent + "  Path:", path
			indent += "  "
			deps = impl.dependencies
			if command is not None:
				deps += sels.commands[command].requires
			for child in deps:
				if isinstance(child, model.InterfaceDependency):
					if child.qdom.name == 'runner':
						child_command = command + 1
					else:
						child_command = None
					print_node(child.interface, child_command, indent)
		else:
			print indent + "  No selected version"


	if sels.commands:
		print_node(sels.interface, 0, "")
	else:
		print_node(sels.interface, None, "")
