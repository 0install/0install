import os, sys

from policy import policy
from model import *

def do_env_binding(binding, iface):
	impl = get_impl(iface)
	extra = os.path.join(impl.path, binding.insert)
	if binding.name in os.environ:
		os.environ[binding.name] = extra + ':' + os.environ[binding.name]
	else:
		os.environ[binding.name] = extra
	#print "%s=%s" % (binding.name, os.environ[binding.name])

def execute(iface, prog, prog_args):
	def setup_bindings(i):
		impl = get_impl(i)
		for dep in impl.dependencies.values():
			dep_iface = dep.get_interface()
			for b in dep.bindings:
				if isinstance(b, EnvironmentBinding):
					do_env_binding(b, dep_iface)
			setup_bindings(dep_iface)
	setup_bindings(iface)
	
	prog_path = os.path.join(policy.implementation[iface].path, prog)
	if not os.path.exists(prog_path):
		print "'%s' does not exist." % prog_path
		print "(implementation '%s' + program '%s')" % (policy.implementation[iface].path, prog)
		sys.exit(1)
	os.execl(prog_path, prog_path, *prog_args)

def get_impl(interface):
	try:
		return policy.implementation[interface]
	except KeyError:
		if not interface.name:
			raise SafeException("We don't have enough information to "
					    "run this program yet. "
					    "Need to download:\n%s" % interface.uri)
		if interface.implementations:
			offline = ""
			if policy.network_use == network_offline:
				offline = "\nThis may be because 'Network Use' is set to Off-line."
			raise SafeException("No usable implementation found for '%s'.%s" %
					(interface.name, offline))
