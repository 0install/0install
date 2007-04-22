"""
Executes a set of implementations as a program.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
from logging import debug, info

from zeroinstall.injector.model import Interface, SafeException, EnvironmentBinding
from zeroinstall.injector.iface_cache import iface_cache

def do_env_binding(binding, path):
	os.environ[binding.name] = binding.get_value(path,
					os.environ.get(binding.name, None))
	info("%s=%s", binding.name, os.environ[binding.name])

def execute(policy, prog_args, dry_run = False, main = None, wrapper = None):
	"""Execute program. On success, doesn't return. On failure, raises an Exception.
	Returns normally only for a successful dry run.
	
	@precondition: C{policy.ready and policy.get_uncached_implementations() == []}
	"""
	iface = iface_cache.get_interface(policy.root)
		
	for needed_iface in policy.implementation:
		impl = policy.implementation[needed_iface]
		assert impl
		for dep in impl.dependencies.values():
			dep_iface = iface_cache.get_interface(dep.interface)
			for b in dep.bindings:
				if isinstance(b, EnvironmentBinding):
					dep_impl = policy.get_implementation(dep_iface)
					do_env_binding(b, policy.get_implementation_path(dep_impl))
	
	root_impl = policy.get_implementation(iface)
	_execute(root_impl, prog_args, dry_run, main, wrapper)

def _get_implementation_path(id):
	if id.startswith('/'): return id
	return iface_cache.stores.lookup(id)

def execute_selections(selections, prog_args, dry_run = False, main = None, wrapper = None):
	"""Execute program. On success, doesn't return. On failure, raises an Exception.
	Returns normally only for a successful dry run.
	
	@precondition: All implementations are in the cache.
	"""
	sels = selections.selections
	for selection in sels.values():
		for dep in selection.dependencies:
			for b in dep.bindings:
				if isinstance(b, EnvironmentBinding):
					dep_impl = sels[dep.interface]
					do_env_binding(b, _get_implementation_path(dep_impl.id))
	
	root_impl = sels[selections.interface]
	_execute(root_impl, prog_args, dry_run, main, wrapper)

def test_selections(selections, prog_args, dry_run, main, wrapper = None):
	"""Run the program in a child process, collecting stdout and stderr.
	@return: the output produced by the process
	@since: 0.27
	"""
	args = []
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

		info("Waiting for test process to finish...")

		pid, status = os.waitpid(child, 0)
		assert pid == child

		output.seek(0)
		results = output.read()
		if status != 0:
			results += "Error from child process: exit code = %d" % status
	finally:
		output.close()
	
	return results

def _execute(root_impl, prog_args, dry_run, main, wrapper):
	assert root_impl is not None

	if main is None:
		main = root_impl.main
	elif main.startswith('/'):
		main = main[1:]
	elif root_impl.main:
		main = os.path.join(os.path.dirname(root_impl.main), main)

	if main is None:
		raise SafeException("Implementation '%s' cannot be executed directly; it is just a library "
				    "to be used by other programs (or missing 'main' attribute)" %
				    root_impl)

	prog_path = os.path.join(_get_implementation_path(root_impl.id), main)
	if not os.path.exists(prog_path):
		raise SafeException("File '%s' does not exist.\n"
				"(implementation '%s' + program '%s')" %
				(prog_path, root_impl.id, main))
	if wrapper:
		prog_args = ['-c', wrapper + ' "$@"', '-', prog_path] + list(prog_args)
		prog_path = '/bin/sh'

	if dry_run:
		print "Would execute:", prog_path
	else:
		info("Executing: %s", prog_path)
		sys.stdout.flush()
		sys.stderr.flush()
		try:
			os.execl(prog_path, prog_path, *prog_args)
		except OSError, ex:
			raise SafeException("Failed to run '%s': %s" % (prog_path, str(ex)))

def find_in_path(prog):
	"""Search $PATH for prog.
	If prog is an absolute path, return it unmodified.
	@param prog: name of executable to find
	@return: the full path of prog, or None if not found
	@since: 0.27
	"""
	if os.path.isabs(prog): return prog
	for d in os.environ['PATH'].split(':'):
		path = os.path.join(d, prog)
		if os.path.isfile(path):
			return path
	return None
