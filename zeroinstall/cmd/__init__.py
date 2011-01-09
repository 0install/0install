"""
The B{0install} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, sys
from optparse import OptionParser
import logging

from zeroinstall import SafeException, NeedDownload
from zeroinstall.injector import model, autopolicy, selections
from zeroinstall.injector.iface_cache import iface_cache

valid_commands = ['select', 'download', 'run', 'update',
		  'config', 'import', 'list', 'add-feed', 'remove-feed']

class UsageError(Exception): pass

def _ensure_standard_fds():
	"Ensure stdin, stdout and stderr FDs exist, to avoid confusion."
	for std in (0, 1, 2):
		try:
			os.fstat(std)
		except OSError:
			fd = os.open('/dev/null', os.O_RDONLY)
			if fd != std:
				os.dup2(fd, std)
				os.close(fd)

def _no_command(command_args):
	"""Handle --help and --version"""
	parser = OptionParser(usage=_("usage: %prog COMMAND\n\nTry --help with one of these:") +
			"\n\n0install " + '\n0install '.join(valid_commands))
	parser.add_option("-V", "--version", help=_("display version information"), action='store_true')

	(options, args) = parser.parse_args(command_args)
	if options.version:
		import zeroinstall
		print "0install (zero-install) " + zeroinstall.version
		print "Copyright (C) 2011 Thomas Leonard"
		print _("This program comes with ABSOLUTELY NO WARRANTY,"
				"\nto the extent permitted by law."
				"\nYou may redistribute copies of this program"
				"\nunder the terms of the GNU Lesser General Public License."
				"\nFor more information about these matters, see the file named COPYING.")
		sys.exit(0)
	parser.print_help()
	sys.exit(2)

def main(command_args):
	"""Act as if 0install was run with the given arguments.
	@arg command_args: array of arguments (e.g. C{sys.argv[1:]})
	@type command_args: [str]
	"""
	_ensure_standard_fds()

	# The first non-option argument is the command name (or "help" if none is found).
	command = None
	for arg in command_args:
		if not arg.startswith('-'):
			command = arg
			break
		elif arg == '--':
			break
	
	verbose = False
	try:
		if command is None:
			return _no_command(command_args)

		if command not in valid_commands:
			raise SafeException(_("Unknown sub-command '%s': try --help") % command)

		# Configure a parser for the given command
		module_name = command.replace('-', '_')
		cmd = __import__('zeroinstall.cmd.' + module_name, globals(), locals(), [module_name], 0)
		parser = OptionParser(usage=_("usage: %%prog %s [OPTIONS] %s") % (command, cmd.syntax))

		parser.add_option("-c", "--console", help=_("never use GUI"), action='store_false', dest='gui')
		parser.add_option("", "--dry-run", help=_("just print what would be executed"), action='store_true')
		parser.add_option("-g", "--gui", help=_("show graphical policy editor"), action='store_true')
		parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
		parser.add_option("", "--with-store", help=_("add an implementation cache"), action='append', metavar='DIR')

		cmd.add_options(parser)
		(options, args) = parser.parse_args(command_args)
		assert args[0] == command

		if options.verbose:
			logger = logging.getLogger()
			if options.verbose == 1:
				logger.setLevel(logging.INFO)
			else:
				logger.setLevel(logging.DEBUG)
			import zeroinstall
			logging.info(_("Running 0install %(version)s %(args)s; Python %(python_version)s"), {'version': zeroinstall.version, 'args': repr(command_args), 'python_version': sys.version})

		args = args[1:]

		if options.with_store:
			from zeroinstall import zerostore
			for x in options.with_store:
				iface_cache.stores.stores.append(zerostore.Store(os.path.abspath(x)))
			logging.info(_("Stores search path is now %s"), iface_cache.stores.stores)

		cmd.handle(options, args)
	except UsageError:
		parser.print_help()
		sys.exit(1)
	except SafeException, ex:
		if verbose: raise
		try:
			print >>sys.stderr, unicode(ex)
		except:
			print >>sys.stderr, repr(ex)
		sys.exit(1)
	return
