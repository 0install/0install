import os, sys
from logging import debug, info

from model import Interface, SafeException, EnvironmentBinding

def do_env_binding(binding, path):
	extra = os.path.join(path, binding.insert)
	if binding.name in os.environ:
		os.environ[binding.name] = extra + ':' + os.environ[binding.name]
	else:
		os.environ[binding.name] = extra
	info("%s=%s", binding.name, os.environ[binding.name])

def execute(policy, prog_args, dry_run = False):
	iface = policy.get_interface(policy.root)
	if not iface.main:
		raise SafeException("Interface '%s' cannot be executed directly; it is just a library "
				    "to be used by other programs (or missing 'main' attribute on the "
				    "root <interface> element)." % iface.name)
		
	def setup_bindings(i):
		impl = policy.get_implementation(i)
		for dep in impl.dependencies.values():
			dep_iface = policy.get_interface(dep.interface)
			for b in dep.bindings:
				if isinstance(b, EnvironmentBinding):
					dep_impl = policy.get_implementation(dep_iface)
					do_env_binding(b, policy.get_implementation_path(dep_impl))
			setup_bindings(dep_iface)
	setup_bindings(iface)
	
	root_impl = policy.get_implementation(iface)
	prog_path = os.path.join(policy.get_implementation_path(root_impl), iface.main)
	if not os.path.exists(prog_path):
		raise SafeException("File '%s' does not exist.\n"
				"(implementation '%s' + program '%s')" %
				(prog_path, policy.implementation[iface].id, iface.main))
	if dry_run:
		print "Would execute:", prog_path
	else:
		info("Executing: %s", prog_path)
		os.execl(prog_path, prog_path, *prog_args)
