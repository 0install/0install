"""
The B{0install list} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall.cmd import UsageError
from zeroinstall.injector.iface_cache import iface_cache

syntax = "PATTERN"

def add_options(parser):
	pass

def handle(options, args):
	if len(args) == 0:
		matches = iface_cache.list_all_interfaces()
	elif len(args) == 1:
		match = args[0].lower()
		matches = [i for i in iface_cache.list_all_interfaces() if match in i.lower()]
	else:
		raise UsageError()

	matches.sort()
	for i in matches:
		print i
