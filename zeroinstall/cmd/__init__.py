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
		self.shell = shell
		self.config = config
		self.cword = int(os.environ['COMP_CWORD']) - 1
		self.response_prefix = ''
		if shell == 'zsh':
			self.cword -= 1

		if shell == 'bash':
			# Bash does crazy splitting (e.g. "http://foo" becomes "http" ":" "//foo")
			# Do our best to reverse that splitting here (inspired by Git completion code)
			command_args = command_args[:]
			while ':' in command_args[1:]:
				i = command_args.index(':', 1)
				combined = command_args[i - 1] + command_args[i]
				if i + 1 < len(command_args):
					combined += command_args[i + 1]
				command_args = command_args[:i - 1] + [combined] + command_args[i + 2:]
				if self.cword > i:
					self.cword -= 2
				elif self.cword == i:
					self.cword -= 1
			# For --opt=value, we get ['--opt', '=', value]. Just get rid of the '='.
			if self.cword > 0 and command_args[self.cword - 1] == '=':
				del command_args[self.cword - 1]
				self.cword -= 1
			elif command_args[self.cword] == '=':
				command_args[self.cword] = ''
			#print(command_args, self.cword, file = sys.stderr)
			self.command_args = command_args

		if self.cword < len(command_args):
			self.current = command_args[self.cword]
		else:
			self.current = ''

		if shell == 'zsh':
			if self.current.startswith('--') and '=' in self.current:
				# Split "--foo=bar" into "--foo", "bar"
				name, value = self.current.split('=', 1)
				command_args[self.cword:self.cword + 1] = [name, value]
				self.cword += 1
				self.current = command_args[self.cword]
				self.response_prefix = name + '='
			else:
				self.response_prefix = ''

		self.command_args = command_args

	def got_command(self, command, pos):
		#print("found %s at %s [cword = %d]" % (command, pos, self.cword), file = sys.stderr)
		if pos == self.cword:
			for command in valid_commands:
				self.add("filter", command)
			sys.exit(0)

	def complete(self, parser, cmd):
		opts = {}
		for opt in parser.option_list:
			for name in opt._short_opts:
				opts[name] = opt
			for name in opt._long_opts:
				opts[name] = opt

		options_possible = True
		arg_word = -1
		args = []
		consume_args = 0
		complete_option_arg = None	# (option, args, arg pos)
		#logger.warning("%s at %d", self.command_args, self.cword)
		for i, a in enumerate(self.command_args):
			#logger.warning("%d %s (%d)", i, a, options_possible)
			if consume_args > 0:
				#print("consume " + a, file=sys.stderr)
				consume_args -= 1
			elif a == '--' and options_possible and i != self.cword:
				options_possible = False
			elif a.startswith('-') and options_possible:
				if i == self.cword:
					self._complete_option(parser)
					return
				# Does it take an argument?
				option_with_args = None
				if a.startswith('--'):
					opt = opts.get(a, None)
					if opt and opt.nargs:
						option_with_args = opt
				else:
					for l in a[1:]:
						opt = opts.get('-' + l, None)
						if opt and opt.nargs:
							option_with_args = opt
							break

				if option_with_args:
					consume_args = option_with_args.nargs

					option_arg_index = self.cword - i - 1
					if option_arg_index >= 0 and option_arg_index < consume_args:
						complete_option_arg = (option_with_args,
								       self.command_args[i + 1 : i + 1 + consume_args],
								       option_arg_index)
			else:
				if len(args) > 0 and options_possible and not parser.allow_interspersed_args:
					options_possible = False
				args.append(a)
				if i < self.cword:
					arg_word += 1

		if complete_option_arg is None:
			if hasattr(cmd, 'complete'):
				if arg_word == len(args) - 1: args.append('')
				cmd.complete(self, args[1:], arg_word)
		else:
			metavar = complete_option_arg[0].metavar
			#logger.warning("complete option arg %s %s as %s", args[1:], complete_option_arg, metavar)
			if metavar == 'DIR':
				self.expand_files()
			elif metavar == 'OS':
				for value in ["Cygwin", "Darwin", "FreeBSD", "Linux", "MacOSX", "Windows"]:
					self.add("filter", value)
			elif metavar == 'CPU':
				for value in ["src", "i386", "i486", "i586", "i686", "ppc", "ppc64", "x86_64"]:
					self.add("filter", value)
			elif metavar == 'URI RANGE':
				if complete_option_arg[2] == 0:
					# When completing the URI, contextualise to the app's selections, if possible
					if len(args) > 1:
						app = self.config.app_mgr.lookup_app(args[1], missing_ok = True)
						if app:
							for uri in app.get_selections().selections:
								self.add("filter", uri)
							return
					# Otherwise, complete on all cached URIs
					self.expand_interfaces()
				else:
					self.expand_range(complete_option_arg[1][0])
			elif metavar in ('RANGE', 'VERSION'):
				if len(args) > 1:
					self.expand_range(args[1], maybe_app = True, range_ok = metavar == 'RANGE')
			elif metavar == 'HASH':
				from zeroinstall.zerostore import manifest
				for alg in sorted(manifest.algorithms):
					self.add("filter", alg)
			#else: logger.warning("%r", metavar)

	def _complete_option(self, parser):
		if len(self.current) < 2 or self.current.startswith('--'):
			# Long option, or nothing yet
			for opt in parser.option_list:
				for o in opt._long_opts:
					self.add("filter", o)
		else:
			# Short option: if it's valid, complete it.
			# Otherwise, reject it.
			valid = set()
			for opt in parser.option_list:
				for o in opt._short_opts:
					valid.add(o[1:])
			if all(char in valid for char in self.current[1:]):
				self.add("add", self.current)

	def expand_range(self, uri, maybe_app = False, range_ok = True):
		if maybe_app:
			app = self.config.app_mgr.lookup_app(uri, missing_ok = True)
			if app:
				uri = app.get_requirements().interface_uri

		iface_cache = self.config.iface_cache
		iface = iface_cache.get_interface(uri)
		versions = [impl.get_version() for impl in iface_cache.get_implementations(iface)]

		if range_ok and '..' in self.current:
			prefix = self.current.split('..', 1)[0] + '..!'
		else:
			prefix = ''

		for v in sorted(versions):
			#logger.warning(prefix + v)
			self.add("filter", prefix + v)

	def expand_apps(self):
		for app in self.config.app_mgr.iterate_apps():
			self.add("filter", app)

	def expand_files(self):
		print("file")

	def expand_interfaces(self):
		c = self.current
		if 'http://'.startswith(c[:7]) or 'https://'.startswith(c[:8]):
			if c.count('/') < 3:
				# Start with just the domains
				import re
				start = re.compile('(https?://[^/]+/).*')
				starts = set()
				for iface in self.config.iface_cache.list_all_interfaces():
					if not iface.startswith(c):continue
					match = start.match(iface)
					if match:
						starts.add(match.group(1))
				for s in sorted(starts):
					self.add("prefix", s)
			else:
				for iface in self.config.iface_cache.list_all_interfaces():
					if iface.startswith(c):
						self.add("filter", iface)

		if '://' not in c:
			self.expand_files()

	def add_filtered(self, value):
		"""Add this value, but only if it matches the prefix."""
		self.add("filter", value)

	def add(self, type, value):
		"""Types are:
		add - a raw string to add
		filter - a string to add only if it matches
		prefix - a completion that doesn't insert a space after it."""
		if self.shell == 'bash':
			if ':' in self.current:
				ignored = self.current.rsplit(':', 1)[0] + ':'
				if not value.startswith(ignored): return
				value = value[len(ignored):]
				#print(">%s<" % value, file = sys.stderr)
			if type != 'prefix':
				value += ' '
		print(type, self.response_prefix + value)

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
