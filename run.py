import os, sys

def execute(selection, iface, prog, prog_args):
	selection.setup_bindings()
	
	prog_path = os.path.join(selection[iface].path, prog)
	if not os.path.exists(prog_path):
		print "'%s' does not exist." % prog_path
		print "(implementation '%s' + program '%s')" % (chosen.path, prog)
		sys.exit(1)
	os.execl(prog_path, prog_path, *prog_args)
