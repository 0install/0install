"""
The B{0install run} command-line interface.
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from optparse import OptionParser
import os, sys
import logging

from zeroinstall import cmd, SafeException, _
from zeroinstall.cmd import UsageError, select
from zeroinstall.injector import model, autopolicy, selections, handler
from zeroinstall.injector.iface_cache import iface_cache

syntax = "URI [ARGS]"

def add_options(parser):
	select.add_generic_select_options(parser)
	parser.add_option("-m", "--main", help=_("name of the file to execute"))
	parser.add_option("-w", "--wrapper", help=_("execute program using a debugger, etc"), metavar='COMMAND')
	parser.disable_interspersed_args()

def handle(options, args):
	if len(args) < 1:
		raise UsageError()
	iface_uri = model.canonical_iface_uri(args[0])
	prog_args = args[1:]

	def test_callback(sels):
		from zeroinstall.injector import run
		return run.test_selections(sels, prog_args,
					     False,	# dry-run
					     options.main)

	sels = select.get_selections(options, iface_uri,
				select_only = False, download_only = False,
				test_callback = test_callback)
	if not sels:
		sys.exit(1)	# Aborted by user

	from zeroinstall.injector import run
	run.execute_selections(sels, prog_args, main = options.main, wrapper = options.wrapper)
