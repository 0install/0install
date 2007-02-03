"""
The B{0launch} command-line interface.

This code is here, rather than in B{0launch} itself, simply so that it gets byte-compiled at
install time.
"""

import os, sys
from optparse import OptionParser
import logging

#def program_log(msg): os.access('MARK: 0launch: ' + msg, os.F_OK)
#import __main__
#__main__.__builtins__.program_log = program_log
#program_log('0launch ' + ' '.join((sys.argv[1:])))

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
		os.fstat(std)

	parser = OptionParser(usage="usage: %prog [options] interface [args]\n"
				    "       %prog --list [search-term]\n"
				    "       %prog --import [signed-interface-files]\n"
				    "       %prog --feed [interface]")
	parser.add_option("", "--before", help="choose a version before this", metavar='VERSION')
	parser.add_option("-c", "--console", help="never use GUI", action='store_false', dest='gui')
	parser.add_option("-d", "--download-only", help="fetch but don't run", action='store_true')
	parser.add_option("-D", "--dry-run", help="just print actions", action='store_true')
	parser.add_option("-f", "--feed", help="add or remove a feed", action='store_true')
	parser.add_option("-g", "--gui", help="show graphical policy editor", action='store_true')
	parser.add_option("-i", "--import", help="import from files, not from the network", action='store_true')
	parser.add_option("-l", "--list", help="list all known interfaces", action='store_true')
	parser.add_option("-m", "--main", help="name of the file to execute")
	parser.add_option("", "--not-before", help="minimum version to choose", metavar='VERSION')
	parser.add_option("-o", "--offline", help="try to avoid using the network", action='store_true')
	parser.add_option("-r", "--refresh", help="refresh all used interfaces", action='store_true')
	parser.add_option("-s", "--source", help="select source code", action='store_true')
	parser.add_option("-v", "--verbose", help="more verbose output", action='count')
	parser.add_option("-V", "--version", help="display version information", action='store_true')
	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(command_args)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)

	from zeroinstall.injector import model, download, autopolicy, namespaces

	if options.list:
		from zeroinstall.injector.iface_cache import iface_cache
		if len(args) == 0:
			match = None
			matches = iface_cache.list_all_interfaces()
		elif len(args) == 1:
			match = args[0].lower()
			matches = [i for i in iface_cache.list_all_interfaces() if match in i.lower()]
		else:
			parser.print_help()
			sys.exit(1)

		matches.sort()
		for i in matches:
			print i
		sys.exit(0)

	if options.version:
		import zeroinstall
		print "0launch (zero-install) " + zeroinstall.version
		print "Copyright (C) 2006 Thomas Leonard"
		print "This program comes with ABSOLUTELY NO WARRANTY,"
		print "to the extent permitted by law."
		print "You may redistribute copies of this program"
		print "under the terms of the GNU General Public License."
		print "For more information about these matters, see the file named COPYING."
		sys.exit(0)

	if len(args) < 1:
		if options.gui:
			args = [namespaces.injector_gui_uri]
			options.download_only = True
		else:
			parser.print_help()
			sys.exit(1)

	try:
		if getattr(options, 'import'):
			from zeroinstall.injector import gpg, handler
			from zeroinstall.injector.iface_cache import iface_cache, PendingFeed
			from xml.dom import minidom
			for x in args:
				if not os.path.isfile(x):
					raise model.SafeException("File '%s' does not exist" % x)
				logging.info("Importing from file '%s'", x)
				signed_data = file(x)
				data, sigs = gpg.check_stream(signed_data)
				doc = minidom.parseString(data.read())
				uri = doc.documentElement.getAttribute('uri')
				if not uri:
					raise model.SafeException("Missing 'uri' attribute on root element in '%s'" % x)
				iface = iface_cache.get_interface(uri)
				logging.info("Importing information about interface %s", iface)
				signed_data.seek(0)
				pending = PendingFeed(uri, signed_data)
				iface_cache.add_pending(pending)

				def keys_ready():
					if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
						handler.confirm_trust_keys(iface, pending.sigs, pending.new_xml)

				handler = handler.Handler()
				pending.begin_key_downloads(handler, keys_ready)
				handler.wait_for_downloads()

			sys.exit(0)
		
		if getattr(options, 'feed'):
			from zeroinstall.injector import iface_cache, writer
			from xml.dom import minidom
			for x in args:
				print "Feed '%s':\n" % x
				x = model.canonical_iface_uri(x)
				policy = autopolicy.AutoPolicy(x, download_only = True, dry_run = options.dry_run)
				if options.offline:
					policy.network_use = model.network_offline
				policy.recalculate_with_dl()
				interfaces = policy.get_feed_targets(policy.root)
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
						raise model.SafeException("Aborted at user request.")
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
					iface.feeds.remove(feed)
				else:
					iface.feeds.append(model.Feed(x, arch = None, user_override = True))
				writer.save_interface(iface)
				print "\nFeed list for interface '%s' is now:" % iface.get_name()
				if iface.feeds:
					for f in iface.feeds:
						print "- " + f.uri
				else:
					print "(no feeds)"
			sys.exit(0)
		
		iface_uri = model.canonical_iface_uri(args[0])

		# Singleton instance used everywhere...
		policy = autopolicy.AutoPolicy(iface_uri,
					download_only = bool(options.download_only),
					dry_run = options.dry_run,
					src = options.source)

		if options.before or options.not_before:
			policy.root_restrictions.append(model.Restriction(model.parse_version(options.before),
									  model.parse_version(options.not_before)))

		if options.offline:
			policy.network_use = model.network_offline

		# Note that need_download() triggers a recalculate()
		if options.refresh or options.gui:
			# We could run immediately, but the user asked us not to
			can_run_immediately = False
		else:
			can_run_immediately = (not policy.need_download()) and policy.ready

		if can_run_immediately:
			if policy.stale_feeds:
				# There are feeds we should update, but we can run without them.
				# Do the update in the background while the program is running.
				import background
				background.spawn_background_update(policy)
			policy.execute(args[1:], main = options.main)
			assert options.download_only or options.dry_run
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
	except model.SafeException, ex:
		if options.verbose: raise
		print >>sys.stderr, ex
		sys.exit(1)

	if options.gui:
		policy.set_root(namespaces.injector_gui_uri)
		policy.src = False

		# Try to start the GUI without using the network.
		# The GUI can refresh itself if it wants to.
		policy.freshness = 0
		policy.network_use = model.network_offline

		prog_args = [iface_uri] + args[1:]
		# Options apply to actual program, not GUI
		if options.download_only:
			policy.download_only = False
			prog_args.insert(0, '--download-only')
		if options.refresh:
			options.refresh = False
			prog_args.insert(0, '--refresh')
		if options.not_before:
			prog_args.insert(0, options.not_before)
			prog_args.insert(0, '--not-before')
		if options.before:
			prog_args.insert(0, options.before)
			prog_args.insert(0, '--before')
		if options.source:
			prog_args.insert(0, '--source')
		if options.main:
			prog_args = ['--main', options.main] + prog_args
			options.main = None
		del policy.root_restrictions[:]
	else:
		prog_args = args[1:]

	try:
		#program_log('download_and_execute ' + iface_uri)
		policy.download_and_execute(prog_args, refresh = bool(options.refresh), main = options.main)
	except autopolicy.NeedDownload, ex:
		print ex
		sys.exit(0)
	except model.SafeException, ex:
		if options.verbose: raise
		print >>sys.stderr, ex
		sys.exit(1)
