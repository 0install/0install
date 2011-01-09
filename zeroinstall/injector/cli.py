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
from zeroinstall.cmd import UsageError

#def program_log(msg): os.access('MARK: 0launch: ' + msg, os.F_OK)
#import __main__
#__main__.__builtins__.program_log = program_log
#program_log('0launch ' + ' '.join((sys.argv[1:])))

def _manage_feeds(options, args):
	from zeroinstall.injector import writer
	from zeroinstall.injector.handler import Handler
	from zeroinstall.injector.policy import Policy

	def find_feed_import(iface, feed_url):
		for f in iface.extra_feeds:
			if f.uri == feed_url:
				return f
		return None

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
			if find_feed_import(interfaces[i], x):
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
		feed_import = find_feed_import(iface, x)
		if feed_import:
			iface.extra_feeds.remove(feed_import)
		else:
			iface.extra_feeds.append(model.Feed(x, arch = None, user_override = True))
		writer.save_interface(iface)
		print '\n' + _("Feed list for interface '%s' is now:") % iface.get_name()
		if iface.extra_feeds:
			for f in iface.extra_feeds:
				print "- " + f.uri
		else:
			print _("(no feeds)")

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
	parser.add_option("", "--command", help=_("command to select"), metavar='COMMAND')
	parser.add_option("-c", "--console", help=_("never use GUI"), action='store_false', dest='gui')
	parser.add_option("", "--cpu", help=_("target CPU type"), metavar='CPU')
	parser.add_option("-d", "--download-only", help=_("fetch but don't run"), action='store_true')
	parser.add_option("-D", "--dry-run", help=_("just print actions"), action='store_true')
	parser.add_option("-f", "--feed", help=_("add or remove a feed"), action='store_true')
	parser.add_option("", "--get-selections", help=_("write selected versions as XML"), action='store_true', dest='xml')
	parser.add_option("-g", "--gui", help=_("show graphical policy editor"), action='store_true')
	parser.add_option("-i", "--import", help=_("import from files, not from the network"), action='store_true')
	parser.add_option("-l", "--list", help=_("list all known interfaces"), action='store_true')
	parser.add_option("-m", "--main", help=_("name of the file to execute"))
	parser.add_option("", "--message", help=_("message to display when interacting with user"))
	parser.add_option("", "--not-before", help=_("minimum version to choose"), metavar='VERSION')
	parser.add_option("", "--os", help=_("target operation system type"), metavar='OS')
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')
	parser.add_option("-r", "--refresh", help=_("refresh all used interfaces"), action='store_true')
	parser.add_option("", "--select-only", help=_("only download the feeds"), action='store_true')
	parser.add_option("", "--set-selections", help=_("run versions specified in XML file"), metavar='FILE')
	parser.add_option("", "--show", help=_("show where components are installed"), action='store_true')
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

	if options.select_only or options.show:
		options.download_only = True

	if options.with_store:
		from zeroinstall import zerostore
		for x in options.with_store:
			iface_cache.stores.stores.append(zerostore.Store(os.path.abspath(x)))
		logging.info(_("Stores search path is now %s"), iface_cache.stores.stores)

	if options.set_selections:
		args = [options.set_selections] + args

	try:
		if options.list:
			from zeroinstall.cmd import list
			list.handle(options, args)
		elif options.version:
			import zeroinstall
			print "0launch (zero-install) " + zeroinstall.version
			print "Copyright (C) 2010 Thomas Leonard"
			print _("This program comes with ABSOLUTELY NO WARRANTY,"
					"\nto the extent permitted by law."
					"\nYou may redistribute copies of this program"
					"\nunder the terms of the GNU Lesser General Public License."
					"\nFor more information about these matters, see the file named COPYING.")
		elif getattr(options, 'import'):
			# (import is a keyword)
			cmd = __import__('zeroinstall.cmd.import', globals(), locals(), ["import"], 0)
			cmd.handle(options, args)
		elif options.feed:
			_manage_feeds(options, args)
		elif options.select_only:
			from zeroinstall.cmd import select
			if not options.show:
				options.quiet = True
			select.handle(options, args)
		elif options.download_only or options.xml or options.show:
			from zeroinstall.cmd import download
			download.handle(options, args)
		else:
			if len(args) < 1:
				if options.gui:
					from zeroinstall import helpers
					return helpers.get_selections_gui(None, [])
				else:
					raise UsageError()
			else:
				from zeroinstall.cmd import run
				run.handle(options, args)
	except NeedDownload, ex:
		# This only happens for dry runs
		print ex
	except UsageError:
		parser.print_help()
		sys.exit(1)
	except SafeException, ex:
		if options.verbose: raise
		try:
			print >>sys.stderr, unicode(ex)
		except:
			print >>sys.stderr, repr(ex)
		sys.exit(1)
