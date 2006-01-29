# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
from logging import debug, info

from model import Interface, SafeException, EnvironmentBinding

def do_env_binding(binding, path):
	os.environ[binding.name] = binding.get_value(path,
					os.environ.get(binding.name, None))
	info("%s=%s", binding.name, os.environ[binding.name])

def execute(policy, prog_args, dry_run = False, main = None):
	iface = policy.get_interface(policy.root)
		
	for needed_iface in policy.implementation:
		impl = policy.implementation[needed_iface]
		assert impl
		for dep in impl.dependencies.values():
			dep_iface = policy.get_interface(dep.interface)
			for b in dep.bindings:
				if isinstance(b, EnvironmentBinding):
					dep_impl = policy.get_implementation(dep_iface)
					do_env_binding(b, policy.get_implementation_path(dep_impl))
	
	root_impl = policy.get_implementation(iface)
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

	prog_path = os.path.join(policy.get_implementation_path(root_impl), main)
	if not os.path.exists(prog_path):
		raise SafeException("File '%s' does not exist.\n"
				"(implementation '%s' + program '%s')" %
				(prog_path, policy.implementation[iface].id, main))
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
