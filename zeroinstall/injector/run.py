"""
Executes a set of implementations as a program.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _
import os, sys
from logging import info, debug
from string import Template

from zeroinstall.injector.model import SafeException, EnvironmentBinding, ExecutableBinding, Command, Dependency
from zeroinstall.injector import namespaces, qdom
from zeroinstall.support import basedir

def do_env_binding(binding, path):
	"""Update this process's environment by applying the binding.
	@param binding: the binding to apply
	@type binding: L{model.EnvironmentBinding}
	@param path: the selected implementation
	@type path: str"""
	if binding.insert is not None and path is None:
		# Skip insert bindings for package implementations
		debug("not setting %s as we selected a package implementation", binding.name)
		return
	os.environ[binding.name] = binding.get_value(path,
					os.environ.get(binding.name, None))
	info("%s=%s", binding.name, os.environ[binding.name])

def execute(policy, prog_args, dry_run = False, main = None, wrapper = None):
	"""Execute program. On success, doesn't return. On failure, raises an Exception.
	Returns normally only for a successful dry run.
	@deprecated: use L{execute_selections} instead
	@param policy: a policy with the selected versions
	@type policy: L{policy.Policy}
	@param prog_args: arguments to pass to the program
	@type prog_args: [str]
	@param dry_run: if True, just print a message about what would have happened
	@type dry_run: bool
	@param main: the name of the binary to run, or None to use the default
	@type main: str
	@param wrapper: a command to use to actually run the binary, or None to run the binary directly
	@type wrapper: str
	@precondition: C{policy.ready and policy.get_uncached_implementations() == []}
	"""
	import warnings
	warnings.warn("run.execute is deprecated; use execute_selections instead", DeprecationWarning, 2)
	execute_selections(policy.solver.selections, prog_args, dry_run, main, wrapper)

def test_selections(selections, prog_args, dry_run, main):
	"""Run the program in a child process, collecting stdout and stderr.
	@return: the output produced by the process
	@since: 0.27
	"""
	import tempfile
	output = tempfile.TemporaryFile(prefix = '0launch-test')
	try:
		child = os.fork()
		if child == 0:
			# We are the child
			try:
				try:
					os.dup2(output.fileno(), 1)
					os.dup2(output.fileno(), 2)
					execute_selections(selections, prog_args, dry_run, main)
				except:
					import traceback
					traceback.print_exc()
			finally:
				sys.stdout.flush()
				sys.stderr.flush()
				os._exit(1)

		info(_("Waiting for test process to finish..."))

		pid, status = os.waitpid(child, 0)
		assert pid == child

		output.seek(0)
		results = output.read()
		if status != 0:
			results += _("Error from child process: exit code = %d") % status
	finally:
		output.close()

	return results

def _process_args(args, element):
	"""Append each <arg> under <element> to args, performing $-expansion."""
	for child in element.childNodes:
		if child.uri == namespaces.XMLNS_IFACE and child.name == 'arg':
			args.append(Template(child.content).substitute(os.environ))

class Setup(object):
	"""@since: 1.2"""
	stores = None
	selections = None
	_exec_bindings = None
	_checked_runenv = False

	def __init__(self, stores, selections):
		"""@param stores: where to find cached implementations
		@type stores: L{zerostore.Stores}"""
		self.stores = stores
		self.selections = selections

	def build_command(self, command_iface, command_name, user_command = None):
		"""Create a list of strings to be passed to exec to run the <command>s in the selections.
		@param command_iface: the interface of the program being run
		@type command_iface: str
		@param command_name: the name of the command being run
		@type command_name: str
		@param user_command: a custom command to use instead
		@type user_command: L{model.Command}
		@return: the argument list
		@rtype: [str]"""

		assert command_name

		prog_args = []
		sels = self.selections.selections

		while command_name:
			command_sel = sels[command_iface]

			if user_command is None:
				command = command_sel.get_command(command_name)
			else:
				command = user_command
				user_command = None

			command_args = []

			# Add extra arguments for runner
			runner = command.get_runner()
			if runner:
				command_iface = runner.interface
				command_name = runner.command
				_process_args(command_args, runner.qdom)
			else:
				command_iface = None
				command_name = None

			# Add main program path
			command_path = command.path
			if command_path is not None:
				if command_sel.id.startswith('package:'):
					prog_path = command_path
				else:
					if command_path.startswith('/'):
						raise SafeException(_("Command path must be relative, but '%s' starts with '/'!") %
									command_path)
					prog_path = os.path.join(self._get_implementation_path(command_sel), command_path)

				assert prog_path is not None

				if not os.path.exists(prog_path):
					raise SafeException(_("File '%(program_path)s' does not exist.\n"
							"(implementation '%(implementation_id)s' + program '%(main)s')") %
							{'program_path': prog_path, 'implementation_id': command_sel.id,
							'main': command_path})

				command_args.append(prog_path)

			# Add extra arguments for program
			_process_args(command_args, command.qdom)

			prog_args = command_args + prog_args

		# Each command is run by the next, but the last one is run by exec, and we
		# need a path for that.
		if command.path is None:
			raise SafeException("Missing 'path' attribute on <command>")

		return prog_args

	def _get_implementation_path(self, impl):
		if impl.id.startswith('package:'): return None
		return impl.local_path or self.stores.lookup_any(impl.digests)

	def prepare_env(self):
		"""Do all the environment bindings in the selections (setting os.environ)."""
		self._exec_bindings = []

		def _do_bindings(impl, bindings, iface):
			for b in bindings:
				self.do_binding(impl, b, iface)

		def _do_deps(deps):
			for dep in deps:
				dep_impl = sels.get(dep.interface, None)
				if dep_impl is None:
					assert dep.importance != Dependency.Essential, dep
				else:
					_do_bindings(dep_impl, dep.bindings, dep.interface)

		sels = self.selections.selections
		for selection in sels.values():
			_do_bindings(selection, selection.bindings, selection.interface)
			_do_deps(selection.dependencies)

			# Process commands' dependencies' bindings too
			for command in selection.get_commands().values():
				_do_bindings(selection, command.bindings, selection.interface)
				_do_deps(command.requires)

		# Do these after <environment>s, because they may do $-expansion
		for binding, iface in self._exec_bindings:
			self.do_exec_binding(binding, iface)
		self._exec_bindings = None
	
	def do_binding(self, impl, binding, iface):
		"""Called by L{prepare_env} for each binding.
		Sub-classes may wish to override this.
		@param impl: the selected implementation
		@type impl: L{selections.Selection}
		@param binding: the binding to be processed
		@type binding: L{model.Binding}
		@param iface: the interface containing impl
		@type iface: L{model.Interface}
		"""
		if isinstance(binding, EnvironmentBinding):
			do_env_binding(binding, self._get_implementation_path(impl))
		elif isinstance(binding, ExecutableBinding):
			if isinstance(iface, Dependency):
				import warnings
				warnings.warn("Pass an interface URI instead", DeprecationWarning, 2)
				iface = iface.interface
			self._exec_bindings.append((binding, iface))

	def do_exec_binding(self, binding, iface):
		assert iface is not None
		name = binding.name
		if '/' in name or name.startswith('.') or "'" in name:
			raise SafeException("Invalid <executable> name '%s'" % name)
		exec_dir = basedir.save_cache_path(namespaces.config_site, namespaces.config_prog, 'executables', name)
		exec_path = os.path.join(exec_dir, name)

		if not self._checked_runenv:
			self._check_runenv()

		if not os.path.exists(exec_path):
			# Symlink ~/.cache/0install.net/injector/executables/$name/$name to runenv.py
			os.symlink('../../runenv.py', exec_path)
			os.chmod(exec_dir, 0o500)

		if binding.in_path:
			path = os.environ["PATH"] = exec_dir + os.pathsep + os.environ["PATH"]
			info("PATH=%s", path)
		else:
			os.environ[name] = exec_path
			info("%s=%s", name, exec_path)

		import json
		args = self.build_command(iface, binding.command)
		os.environ["0install-runenv-" + name] = json.dumps(args)

	def _check_runenv(self):
		# Create the runenv.py helper script under ~/.cache if missing or out-of-date
		main_dir = basedir.save_cache_path(namespaces.config_site, namespaces.config_prog)
		runenv = os.path.join(main_dir, 'runenv.py')
		expected_contents = "#!%s\nfrom zeroinstall.injector import _runenv; _runenv.main()\n" % sys.executable

		actual_contents = None
		if os.path.exists(runenv):
			with open(runenv) as s:
				actual_contents = s.read()

		if actual_contents != expected_contents:
			import tempfile
			tmp = tempfile.NamedTemporaryFile('w', dir = main_dir, delete = False)
			info("Updating %s", runenv)
			tmp.write(expected_contents)
			tmp.close()
			os.chmod(tmp.name, 0555)
			os.rename(tmp.name, runenv)

		self._checked_runenv = True

def execute_selections(selections, prog_args, dry_run = False, main = None, wrapper = None, stores = None):
	"""Execute program. On success, doesn't return. On failure, raises an Exception.
	Returns normally only for a successful dry run.
	@param selections: the selected versions
	@type selections: L{selections.Selections}
	@param prog_args: arguments to pass to the program
	@type prog_args: [str]
	@param dry_run: if True, just print a message about what would have happened
	@type dry_run: bool
	@param main: the name of the binary to run, or None to use the default
	@type main: str
	@param wrapper: a command to use to actually run the binary, or None to run the binary directly
	@type wrapper: str
	@since: 0.27
	@precondition: All implementations are in the cache.
	"""
	#assert stores is not None
	if stores is None:
		from zeroinstall import zerostore
		stores = zerostore.Stores()

	setup = Setup(stores, selections)

	commands = selections.commands
	if main is not None:
		# Replace first command with user's input
		if main.startswith('/'):
			main = main[1:]			# User specified a path relative to the package root
		else:
			old_path = commands[0].path
			assert old_path, "Can't use a relative replacement main when there is no original one!"
			main = os.path.join(os.path.dirname(old_path), main)	# User main is relative to command's name
		# Copy all child nodes (e.g. <runner>) except for the arguments
		user_command_element = qdom.Element(namespaces.XMLNS_IFACE, 'command', {'path': main})
		if commands:
			for child in commands[0].qdom.childNodes:
				if child.uri == namespaces.XMLNS_IFACE and child.name == 'arg':
					continue
				user_command_element.childNodes.append(child)
		user_command = Command(user_command_element, None)
	else:
		user_command = None

	setup.prepare_env()
	prog_args = setup.build_command(selections.interface, selections.command, user_command) + prog_args

	if wrapper:
		prog_args = ['/bin/sh', '-c', wrapper + ' "$@"', '-'] + list(prog_args)

	if dry_run:
		print(_("Would execute: %s") % ' '.join(prog_args))
	else:
		info(_("Executing: %s"), prog_args)
		sys.stdout.flush()
		sys.stderr.flush()
		try:
			os.execv(prog_args[0], prog_args)
		except OSError as ex:
			raise SafeException(_("Failed to run '%(program_path)s': %(exception)s") % {'program_path': prog_args[0], 'exception': str(ex)})
