"""
The B{0install} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger
import os, sys
from optparse import OptionParser
import logging

from zeroinstall import SafeException, DryRun

valid_commands = ['add', 'select', 'show', 'download', 'run', 'update', 'whatchanged', 'destroy',
		  'config', 'import', 'list', 'add-feed', 'remove-feed', 'list-feeds',
		  'man', 'digest']

class UsageError(Exception): pass

def _ensure_standard_fds():
	"Ensure stdin, stdout and stderr FDs exist, to avoid confusion."
	for std in (0, 1, 2):
		try:
			os.fstat(std)
		except OSError:
			fd = os.open(os.devnull, os.O_RDONLY)
			if fd != std:
				os.dup2(fd, std)
				os.close(fd)

class NoCommand:
	"""Handle --help and --version"""

	def add_options(self, parser):
		parser.add_option("-V", "--version", help=_("display version information"), action='store_true')

	def handle(self, config, options, args):
		if options.version:
			import zeroinstall
			print("0install (zero-install) " + zeroinstall.version)
			print("Copyright (C) 2013 Thomas Leonard")
			print(_("This program comes with ABSOLUTELY NO WARRANTY,"
					"\nto the extent permitted by law."
					"\nYou may redistribute copies of this program"
					"\nunder the terms of the GNU Lesser General Public License."
					"\nFor more information about these matters, see the file named COPYING."))
			sys.exit(0)
		raise UsageError()

class _Completion():
	def __init__(self, config, command_args, shell):
		assert shell in ('zsh', 'bash'), shell
		self.config = config
		self.command_args = command_args
		self.cword = int(os.environ['COMP_CWORD']) - 1
		if shell == 'zsh':
			self.cword -= 1
		if self.cword < len(command_args):
			self.current = command_args[self.cword]
		else:
			self.current = ''

	def got_command(self, command, pos):
		#print("found %s at %s [cword = %d]" % (command, pos, self.cword), file = sys.stderr)
		if pos == self.cword:
			for command in valid_commands:
				print("filter", command)
			sys.exit(0)

	def complete(self, parser, cmd):
		if '--' in self.command_args and self.cword > self.command_args.index('--'):
			sys.exit(0)		# Can't complete after "--"
			# (but completing on "--" is OK, because that might be the start of an option)

		# Complete options if the current word starts with '-'
		if self.current.startswith('-'):
			if not parser.allow_interspersed_args:
				args = 0
				for arg in self.command_args[:self.cword]:
					if not arg.startswith('-'):
						args += 1
						if args == 2:
							# We've seen the sub-command and the sub-command's argument
							# before reaching the word we're completing; give up.
							return

			if len(self.current) < 2 or self.current.startswith('--'):
				# Long option, or nothing yet
				for opt in parser.option_list:
					for o in opt._long_opts:
						print("filter", o)
			else:
				# Short option: if it's valid, complete it.
				# Otherwise, reject it.
				valid = set()
				for opt in parser.option_list:
					for o in opt._short_opts:
						valid.add(o[1:])
				if all(char in valid for char in self.current[1:]):
					print("add", self.current)
			sys.exit(0)

		arg_word = self.cword - 1	# Skip command name
		args = []
		for a in self.command_args:
			if a.startswith('-'):
				arg_word -= 1
			else:
				args.append(a)

		if hasattr(cmd, 'complete'):
			if arg_word == len(args) - 1: args.append('')
			cmd.complete(self, args[1:], arg_word)

	def expand_apps(self):
		for app in self.config.app_mgr.iterate_apps():
			print("filter", app)

	def expand_files(self):
		print("file")

	def expand_interfaces(self):
		for iface in self.config.iface_cache.list_all_interfaces():
			print("filter", iface)

	def add_filtered(self, value):
		"""Add this value, but only if it matches the prefix."""
		print("filter", value)

def main(command_args, config = None):
	"""Act as if 0install was run with the given arguments.
	@arg command_args: array of arguments (e.g. C{sys.argv[1:]})
	@type command_args: [str]
	"""
	_ensure_standard_fds()

	if config is None:
		from zeroinstall.injector.config import load_config
		config = load_config()

	completion = None
	if command_args and command_args[0] == '_complete':
		shell = command_args[1]
		command_args = command_args[3:]
		# command_args[2] == "0install"
		completion = _Completion(config, command_args, shell = shell)

	# The first non-option argument is the command name (or "help" if none is found).
	command = None
	for i, arg in enumerate(command_args):
		if not arg.startswith('-'):
			command = arg
			command_args = command_args[:i] + command_args[i + 1:]
			if completion:
				completion.got_command(command, i)
			break
		elif arg == '--':
			break
	else:
		if completion:
			completion.got_command(None, len(command_args))

	verbose = False
	try:
		# Configure a parser for the given command
		if command:
			if command not in valid_commands:
				if completion:
					return
				raise SafeException(_("Unknown sub-command '%s': try --help") % command)

			module_name = command.replace('-', '_')
			cmd = __import__('zeroinstall.cmd.' + module_name, globals(), locals(), [module_name], 0)
			parser = OptionParser(usage=_("usage: %%prog %s [OPTIONS] %s") % (command, cmd.syntax))
		else:
			cmd = NoCommand()
			parser = OptionParser(usage=_("usage: %prog COMMAND\n\nTry --help with one of these:") +
					"\n\n0install " + '\n0install '.join(valid_commands))

		parser.add_option("-c", "--console", help=_("never use GUI"), action='store_false', dest='gui')
		parser.add_option("", "--dry-run", help=_("just print what would be executed"), action='store_true')
		parser.add_option("-g", "--gui", help=_("show graphical policy editor"), action='store_true')
		parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
		parser.add_option("", "--with-store", help=_("add an implementation cache"), action='append', metavar='DIR')

		cmd.add_options(parser)

		if completion:
			completion.complete(parser, cmd)
			return

		(options, args) = parser.parse_args(command_args)
		verbose = options.verbose

		if options.verbose:
			if options.verbose == 1:
				logger.setLevel(logging.INFO)
			else:
				logger.setLevel(logging.DEBUG)
			import zeroinstall
			logger.info(_("Running 0install %(version)s %(args)s; Python %(python_version)s"), {'version': zeroinstall.version, 'args': repr(command_args), 'python_version': sys.version})

		if options.with_store:
			from zeroinstall import zerostore
			for x in options.with_store:
				config.stores.stores.append(zerostore.Store(os.path.abspath(x)))
			logger.info(_("Stores search path is now %s"), config.stores.stores)

		config.handler.dry_run = bool(options.dry_run)
		if config.handler.dry_run:
			if options.gui is True:
				raise SafeException(_("Can't use --gui with --dry-run"))
			options.gui = False

		cmd.handle(config, options, args)
	except KeyboardInterrupt:
		logger.info("KeyboardInterrupt")
		sys.exit(1)
	except UsageError:
		parser.print_help()
		sys.exit(1)
	except DryRun as ex:
		print(_("[dry-run]"), ex)
	except SafeException as ex:
		if verbose: raise
		try:
			from zeroinstall.support import unicode
			print(unicode(ex), file=sys.stderr)
		except:
			print(repr(ex), file=sys.stderr)
		sys.exit(1)
	return
