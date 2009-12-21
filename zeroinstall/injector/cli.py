"""
The B{0launch} command-line interface.

This code is here, rather than in B{0launch} itself, simply so that it gets byte-compiled at
install time.
"""

from zeroinstall import _
import os, sys
from optparse import OptionParser
import logging

from zeroinstall import SafeException, NeedDownload
from zeroinstall.injector import model, autopolicy, selections
from zeroinstall.injector.iface_cache import iface_cache

#def program_log(msg): os.access('MARK: 0launch: ' + msg, os.F_OK)
#import __main__
#__main__.__builtins__.program_log = program_log
#program_log('0launch ' + ' '.join((sys.argv[1:])))

def _list_interfaces(args):
	if len(args) == 0:
		matches = iface_cache.list_all_interfaces()
	elif len(args) == 1:
		match = args[0].lower()
		matches = [i for i in iface_cache.list_all_interfaces() if match in i.lower()]
	else:
		raise UsageError()

	matches.sort()
	for i in matches:
		print i

def _import_feed(args):
	from zeroinstall.support import tasks
	from zeroinstall.injector import gpg, handler
	from zeroinstall.injector.iface_cache import PendingFeed
	from xml.dom import minidom
	handler = handler.Handler()

	for x in args:
		if not os.path.isfile(x):
			raise SafeException(_("File '%s' does not exist") % x)
		logging.info(_("Importing from file '%s'"), x)
		signed_data = file(x)
		data, sigs = gpg.check_stream(signed_data)
		doc = minidom.parseString(data.read())
		uri = doc.documentElement.getAttribute('uri')
		if not uri:
			raise SafeException(_("Missing 'uri' attribute on root element in '%s'") % x)
		iface = iface_cache.get_interface(uri)
		logging.info(_("Importing information about interface %s"), iface)
		signed_data.seek(0)

		pending = PendingFeed(uri, signed_data)

		def run():
			keys_downloaded = tasks.Task(pending.download_keys(handler), "download keys")
			yield keys_downloaded.finished
			tasks.check(keys_downloaded.finished)
			if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
				blocker = handler.confirm_trust_keys(iface, pending.sigs, pending.new_xml)
				if blocker:
					yield blocker
					tasks.check(blocker)
				if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
					raise SafeException(_("No signing keys trusted; not importing"))

		task = tasks.Task(run(), "import feed")

		errors = handler.wait_for_blocker(task.finished)
		if errors:
			raise SafeException(_("Errors during download: ") + '\n'.join(errors))

def _manage_feeds(options, args):
	from zeroinstall.injector import writer
	from zeroinstall.injector.handler import Handler
	from zeroinstall.injector.policy import Policy
	handler = Handler(dry_run = options.dry_run)
	if not args: raise UsageError()
	for x in args:
		print _("Feed '%s':") % x + '\n'
		x = model.canonical_iface_uri(x)
		policy = Policy(x, handler)
		if options.offline:
			policy.network_use = model.network_offline

		feed = iface_cache.get_feed(x)
		if policy.network_use != model.network_offline and policy.is_stale(feed):
			blocker = policy.fetcher.download_and_import_feed(x, iface_cache.iface_cache)
			print _("Downloading feed; please wait...")
			handler.wait_for_blocker(blocker)
			print _("Done")

		interfaces = policy.get_feed_targets(x)
		for i in range(len(interfaces)):
			feed = interfaces[i].get_feed(x)
			if feed:
				print _("%(index)d) Remove as feed for '%(uri)s'") % {'index': i + 1, 'uri': interfaces[i].uri}
			else:
				print _("%(index)d) Add as feed for '%(uri)s'") % {'index': i + 1, 'uri': interfaces[i].uri}
		print
		while True:
			try:
				i = raw_input(_('Enter a number, or CTRL-C to cancel [1]: ')).strip()
			except KeyboardInterrupt:
				print
				raise SafeException(_("Aborted at user request."))
			if i == '':
				i = 1
			else:
				try:
					i = int(i)
				except ValueError:
					i = 0
			if i > 0 and i <= len(interfaces):
				break
			print _("Invalid number. Try again. (1 to %d)") % len(interfaces)
		iface = interfaces[i - 1]
		feed = iface.get_feed(x)
		if feed:
			iface.extra_feeds.remove(feed)
		else:
			iface.extra_feeds.append(model.Feed(x, arch = None, user_override = True))
		writer.save_interface(iface)
		print '\n' + _("Feed list for interface '%s' is now:") % iface.get_name()
		if iface.feeds:
			for f in iface.feeds:
				print "- " + f.uri
		else:
			print _("(no feeds)")

def _normal_mode(options, args):
	from zeroinstall.injector import handler

	if len(args) < 1:
		if options.gui:
			from zeroinstall import helpers
			return helpers.get_selections_gui(None, [])
		else:
			raise UsageError()

	iface_uri = model.canonical_iface_uri(args[0])
	root_iface = iface_cache.get_interface(iface_uri)

	if os.isatty(1):
		h = handler.ConsoleHandler()
	else:
		h = handler.Handler()
	h.dry_run = bool(options.dry_run)

	policy = autopolicy.AutoPolicy(iface_uri,
				handler = h,
				download_only = bool(options.download_only),
				src = options.source)

	if options.before or options.not_before:
		policy.solver.extra_restrictions[root_iface] = [model.VersionRangeRestriction(model.parse_version(options.before),
									      		      model.parse_version(options.not_before))]

	if options.os or options.cpu:
		from zeroinstall.injector import arch
		policy.target_arch = arch.get_architecture(options.os, options.cpu)

	if options.offline:
		policy.network_use = model.network_offline

	if options.get_selections:
		if len(args) > 1:
			raise SafeException(_("Can't use arguments with --get-selections"))
		if options.main:
			raise SafeException(_("Can't use --main with --get-selections"))

	# Note that need_download() triggers a solve
	if options.refresh or options.gui:
		# We could run immediately, but the user asked us not to
		can_run_immediately = False
	else:
		can_run_immediately = (not policy.need_download()) and policy.ready

		stale_feeds = [feed for feed in policy.solver.feeds_used if policy.is_stale(iface_cache.get_feed(feed))]

		if options.download_only and stale_feeds:
			can_run_immediately = False

	if can_run_immediately:
		if stale_feeds:
			if policy.network_use == model.network_offline:
				logging.debug(_("No doing background update because we are in off-line mode."))
			else:
				# There are feeds we should update, but we can run without them.
				# Do the update in the background while the program is running.
				import background
				background.spawn_background_update(policy, options.verbose > 0)
		if options.get_selections:
			_get_selections(policy)
		else:
			if not options.download_only:
				from zeroinstall.injector import run
				run.execute(policy, args[1:], dry_run = options.dry_run, main = options.main, wrapper = options.wrapper)
			else:
				logging.info(_("Downloads done (download-only mode)"))
			assert options.dry_run or options.download_only
		return

	# If the user didn't say whether to use the GUI, choose for them.
	if options.gui is None and os.environ.get('DISPLAY', None):
		options.gui = True
		# If we need to download anything, we might as well
		# refresh all the interfaces first. Also, this triggers
		# the 'checking for updates' box, which is non-interactive
		# when there are no changes to the selection.
		options.refresh = True
		logging.info(_("Switching to GUI mode... (use --console to disable)"))

	prog_args = args[1:]

	try:
		from zeroinstall.injector import run
		if options.gui:
			gui_args = []
			if options.download_only:
				# Just changes the button's label
				gui_args.append('--download-only')
			if options.refresh:
				gui_args.append('--refresh')
			if options.systray:
				gui_args.append('--systray')
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
			sels = _fork_gui(iface_uri, gui_args, prog_args, options)
			if not sels:
				sys.exit(1)		# Aborted
		else:
			#program_log('download_and_execute ' + iface_uri)
			downloaded = policy.solve_and_download_impls(refresh = bool(options.refresh))
			if downloaded:
				policy.handler.wait_for_blocker(downloaded)
			sels = selections.Selections(policy)

		if options.get_selections:
			doc = sels.toDOM()
			doc.writexml(sys.stdout)
			sys.stdout.write('\n')
		elif not options.download_only:
			run.execute_selections(sels, prog_args, options.dry_run, options.main, options.wrapper)

	except NeedDownload, ex:
		# This only happens for dry runs
		print ex

def _fork_gui(iface_uri, gui_args, prog_args, options = None):
	"""Run the GUI to get the selections.
	prog_args and options are used only if the GUI requests a test.
	"""
	from zeroinstall import helpers
	def test_callback(sels):
		from zeroinstall.injector import run
		return run.test_selections(sels, prog_args,
					     bool(options and options.dry_run),
					     options and options.main)
	return helpers.get_selections_gui(iface_uri, gui_args, test_callback)

def _download_missing_selections(options, sels):
	from zeroinstall.injector import fetch
	from zeroinstall.injector.handler import Handler
	handler = Handler(dry_run = options.dry_run)
	fetcher = fetch.Fetcher(handler)
	blocker = sels.download_missing(iface_cache, fetcher)
	if blocker:
		logging.info(_("Waiting for selected implementations to be downloaded..."))
		handler.wait_for_blocker(blocker)

def _get_selections(policy):
	doc = selections.Selections(policy).toDOM()
	doc.writexml(sys.stdout)
	sys.stdout.write('\n')

class UsageError(Exception): pass

def main(command_args):
	"""Act as if 0launch was run with the given arguments.
	@arg command_args: array of arguments (e.g. C{sys.argv[1:]})
	@type command_args: [str]
	"""
	# Ensure stdin, stdout and stderr FDs exist, to avoid confusion
	for std in (0, 1, 2):
		try:
			os.fstat(std)
		except OSError:
			fd = os.open('/dev/null', os.O_RDONLY)
			if fd != std:
				os.dup2(fd, std)
				os.close(fd)

	parser = OptionParser(usage=_("usage: %prog [options] interface [args]\n"
				    "       %prog --list [search-term]\n"
				    "       %prog --import [signed-interface-files]\n"
				    "       %prog --feed [interface]"))
	parser.add_option("", "--before", help=_("choose a version before this"), metavar='VERSION')
	parser.add_option("-c", "--console", help=_("never use GUI"), action='store_false', dest='gui')
	parser.add_option("", "--cpu", help=_("target CPU type"), metavar='CPU')
	parser.add_option("-d", "--download-only", help=_("fetch but don't run"), action='store_true')
	parser.add_option("-D", "--dry-run", help=_("just print actions"), action='store_true')
	parser.add_option("-f", "--feed", help=_("add or remove a feed"), action='store_true')
	parser.add_option("", "--get-selections", help=_("write selected versions as XML"), action='store_true')
	parser.add_option("-g", "--gui", help=_("show graphical policy editor"), action='store_true')
	parser.add_option("-i", "--import", help=_("import from files, not from the network"), action='store_true')
	parser.add_option("-l", "--list", help=_("list all known interfaces"), action='store_true')
	parser.add_option("-m", "--main", help=_("name of the file to execute"))
	parser.add_option("", "--message", help=_("message to display when interacting with user"))
	parser.add_option("", "--not-before", help=_("minimum version to choose"), metavar='VERSION')
	parser.add_option("", "--os", help=_("target operation system type"), metavar='OS')
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')
	parser.add_option("-r", "--refresh", help=_("refresh all used interfaces"), action='store_true')
	parser.add_option("", "--set-selections", help=_("run versions specified in XML file"), metavar='FILE')
	parser.add_option("-s", "--source", help=_("select source code"), action='store_true')
	parser.add_option("", "--systray", help=_("download in the background"), action='store_true')
	parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
	parser.add_option("-V", "--version", help=_("display version information"), action='store_true')
	parser.add_option("", "--with-store", help=_("add an implementation cache"), action='append', metavar='DIR')
	parser.add_option("-w", "--wrapper", help=_("execute program using a debugger, etc"), metavar='COMMAND')
	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(command_args)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)
		import zeroinstall
		logging.info(_("Running 0launch %(version)s %(args)s; Python %(python_version)s"), {'version': zeroinstall.version, 'args': repr(args), 'python_version': sys.version})

	if options.with_store:
		from zeroinstall import zerostore
		for x in options.with_store:
			iface_cache.stores.stores.append(zerostore.Store(os.path.abspath(x)))
		logging.info(_("Stores search path is now %s"), iface_cache.stores.stores)

	try:
		if options.list:
			_list_interfaces(args)
		elif options.version:
			import zeroinstall
			print "0launch (zero-install) " + zeroinstall.version
			print "Copyright (C) 2009 Thomas Leonard"
			print _("This program comes with ABSOLUTELY NO WARRANTY,"
					"\nto the extent permitted by law."
					"\nYou may redistribute copies of this program"
					"\nunder the terms of the GNU Lesser General Public License."
					"\nFor more information about these matters, see the file named COPYING.")
		elif options.set_selections:
			from zeroinstall.injector import qdom, run
			sels = selections.Selections(qdom.parse(file(options.set_selections)))
			_download_missing_selections(options, sels)
			if not options.download_only:
				run.execute_selections(sels, args, options.dry_run, options.main, options.wrapper)
		elif getattr(options, 'import'):
			_import_feed(args)
		elif options.feed:
			_manage_feeds(options, args)
		else:
			_normal_mode(options, args)
	except UsageError:
		parser.print_help()
		sys.exit(1)
	except SafeException, ex:
		if options.verbose: raise
		print >>sys.stderr, ex
		sys.exit(1)
