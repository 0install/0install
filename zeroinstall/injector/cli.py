"""
The B{0launch} command-line interface.

This code is here, rather than in B{0launch} itself, simply so that it gets byte-compiled at
install time.
"""

import os, sys
from optparse import OptionParser
import logging

from zeroinstall import SafeException, NeedDownload
from zeroinstall.injector import model, autopolicy, namespaces
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
	for x in args:
		if not os.path.isfile(x):
			raise SafeException("File '%s' does not exist" % x)
		logging.info("Importing from file '%s'", x)
		signed_data = file(x)
		data, sigs = gpg.check_stream(signed_data)
		doc = minidom.parseString(data.read())
		uri = doc.documentElement.getAttribute('uri')
		if not uri:
			raise SafeException("Missing 'uri' attribute on root element in '%s'" % x)
		iface = iface_cache.get_interface(uri)
		logging.info("Importing information about interface %s", iface)
		signed_data.seek(0)

		pending = PendingFeed(uri, signed_data)

		handler = handler.Handler()

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
					raise SafeException("No signing keys trusted; not importing")

		task = tasks.Task(run(), "import feed")

		errors = handler.wait_for_blocker(task.finished)
		if errors:
			raise SafeException("Errors during download: " + '\n'.join(errors))

def _manage_feeds(options, args):
	from zeroinstall.injector import writer
	from zeroinstall.injector.handler import Handler
	from zeroinstall.injector.policy import Policy
	handler = Handler(dry_run = options.dry_run)
	if not args: raise UsageError()
	for x in args:
		print "Feed '%s':\n" % x
		x = model.canonical_iface_uri(x)
		policy = Policy(x, handler)
		if options.offline:
			policy.network_use = model.network_offline

		feed = iface_cache.get_feed(x)
		if policy.network_use != model.network_offline and policy.is_stale(feed):
			blocker = policy.fetcher.download_and_import_feed(x, iface_cache.iface_cache)
			print "Downloading feed; please wait..."
			handler.wait_for_blocker(blocker)
			print "Done"

		interfaces = policy.get_feed_targets(x)
		for i in range(len(interfaces)):
			feed = interfaces[i].get_feed(x)
			if feed:
				print "%d) Remove as feed for '%s'" % (i + 1, interfaces[i].uri)
			else:
				print "%d) Add as feed for '%s'" % (i + 1, interfaces[i].uri)
		print
		while True:
			try:
				i = raw_input('Enter a number, or CTRL-C to cancel [1]: ').strip()
			except KeyboardInterrupt:
				print
				raise SafeException("Aborted at user request.")
			if i == '':
				i = 1
			else:
				try:
					i = int(i)
				except ValueError:
					i = 0
			if i > 0 and i <= len(interfaces):
				break
			print "Invalid number. Try again. (1 to %d)" % len(interfaces)
		iface = interfaces[i - 1]
		feed = iface.get_feed(x)
		if feed:
			iface.extra_feeds.remove(feed)
		else:
			iface.extra_feeds.append(model.Feed(x, arch = None, user_override = True))
		writer.save_interface(iface)
		print "\nFeed list for interface '%s' is now:" % iface.get_name()
		if iface.feeds:
			for f in iface.feeds:
				print "- " + f.uri
		else:
			print "(no feeds)"

def _normal_mode(options, args):
	if len(args) < 1:
		# You can use -g on its own to edit the GUI's own policy
		# Otherwise, failing to give an interface is an error
		if options.gui:
			args = [namespaces.injector_gui_uri]
			options.download_only = True
		else:
			raise UsageError()

	iface_uri = model.canonical_iface_uri(args[0])
	root_iface = iface_cache.get_interface(iface_uri)

	policy = autopolicy.AutoPolicy(iface_uri,
				download_only = bool(options.download_only),
				dry_run = options.dry_run,
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
			raise SafeException("Can't use arguments with --get-selections")
		if options.main:
			raise SafeException("Can't use --main with --get-selections")

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
				logging.debug("No doing background update because we are in off-line mode.")
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
				logging.info("Downloads done (download-only mode)")
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
		logging.info("Switching to GUI mode... (use --console to disable)")

	prog_args = args[1:]

	try:
		if options.gui:
			from zeroinstall.injector import run
			gui_args = []
			if options.download_only:
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
			sels = _fork_gui(iface_uri, gui_args, prog_args, options)
			if not sels:
				sys.exit(1)		# Aborted
			if options.get_selections:
				doc = sels.toDOM()
				doc.writexml(sys.stdout)
				sys.stdout.write('\n')
			elif not options.download_only:
				run.execute_selections(sels, prog_args, options.dry_run, options.main, options.wrapper)
		else:
			#program_log('download_and_execute ' + iface_uri)
			policy.download_and_execute(prog_args, refresh = bool(options.refresh), main = options.main)
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
		logging.info("Waiting for selected implementations to be downloaded...")
		handler.wait_for_blocker(blocker)

def _get_selections(policy):
	import selections
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

	parser = OptionParser(usage="usage: %prog [options] interface [args]\n"
				    "       %prog --list [search-term]\n"
				    "       %prog --import [signed-interface-files]\n"
				    "       %prog --feed [interface]")
	parser.add_option("", "--before", help="choose a version before this", metavar='VERSION')
	parser.add_option("-c", "--console", help="never use GUI", action='store_false', dest='gui')
	parser.add_option("", "--cpu", help="target CPU type", metavar='CPU')
	parser.add_option("-d", "--download-only", help="fetch but don't run", action='store_true')
	parser.add_option("-D", "--dry-run", help="just print actions", action='store_true')
	parser.add_option("-f", "--feed", help="add or remove a feed", action='store_true')
	parser.add_option("", "--get-selections", help="write selected versions as XML", action='store_true')
	parser.add_option("-g", "--gui", help="show graphical policy editor", action='store_true')
	parser.add_option("-i", "--import", help="import from files, not from the network", action='store_true')
	parser.add_option("-l", "--list", help="list all known interfaces", action='store_true')
	parser.add_option("-m", "--main", help="name of the file to execute")
	parser.add_option("", "--not-before", help="minimum version to choose", metavar='VERSION')
	parser.add_option("", "--os", help="target operation system type", metavar='OS')
	parser.add_option("-o", "--offline", help="try to avoid using the network", action='store_true')
	parser.add_option("-r", "--refresh", help="refresh all used interfaces", action='store_true')
	parser.add_option("", "--set-selections", help="run versions specified in XML file", metavar='FILE')
	parser.add_option("-s", "--source", help="select source code", action='store_true')
	parser.add_option("-v", "--verbose", help="more verbose output", action='count')
	parser.add_option("-V", "--version", help="display version information", action='store_true')
	parser.add_option("-w", "--wrapper", help="execute program using a debugger, etc", metavar='COMMAND')
	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(command_args)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)
		import zeroinstall
		logging.info("Running 0launch %s %s; Python %s", zeroinstall.version, repr(args), sys.version)

	try:
		if options.list:
			_list_interfaces(args)
		elif options.version:
			import zeroinstall
			print "0launch (zero-install) " + zeroinstall.version
			print "Copyright (C) 2007 Thomas Leonard"
			print "This program comes with ABSOLUTELY NO WARRANTY,"
			print "to the extent permitted by law."
			print "You may redistribute copies of this program"
			print "under the terms of the GNU Lesser General Public License."
			print "For more information about these matters, see the file named COPYING."
		elif options.set_selections:
			from zeroinstall.injector import selections, qdom, run
			sels = selections.Selections(qdom.parse(file(options.set_selections)))
			_download_missing_selections(options, sels)
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
