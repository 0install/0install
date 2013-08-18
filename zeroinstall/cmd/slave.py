"""
The B{0install slave} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger, SafeException
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.support import tasks

import json, sys

syntax = ""

if sys.version_info[0] > 2:
	stdin = sys.stdin.buffer
	stdout = sys.stdout.buffer
else:
	stdin = sys.stdin
	stdout = sys.stdout

def add_options(parser):
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')

def do_select_with_refresh(config, options, args):
	(for_op, reqs_json) = args

	requirements = Requirements(None)
	for k, v in reqs_json.items():
		setattr(requirements, k, v)

	if options.offline:
		config.network_use = model.network_offline

	driver = Driver(config = config, requirements = requirements)

	select_only = for_op == 'for-select'
	download_only = for_op == 'for-download'

	if options.gui != False:
		# If the user didn't say whether to use the GUI, choose for them.
		gui_args = driver.requirements.get_as_options()
		if download_only:
			# Just changes the button's label
			gui_args.append('--download-only')
		gui_args.append('--refresh')
		if options.verbose:
			gui_args.insert(0, '--verbose')
			if options.verbose > 1:
				gui_args.insert(0, '--verbose')
		if options.with_store:
			for x in options.with_store:
				gui_args += ['--with-store', x]
		if select_only:
			gui_args.append('--select-only')

		from zeroinstall import helpers
		sels = helpers.get_selections_gui(requirements.interface_uri, gui_args, test_callback = None, use_gui = options.gui)

		if not sels:
			return "Aborted"
		elif sels is helpers.DontUseGUI:
			sels = None
	else:
		sels = None

	if sels is None:
		# Note: --download-only also makes us stop and download stale feeds first.
		downloaded = driver.solve_and_download_impls(refresh = True, select_only = select_only)
		if downloaded:
			tasks.wait_for_blocker(downloaded)
		sels = driver.solver.selections

	doc = sels.toDOM()
	return doc.toxml()

def handle(config, options, args):
	if args:
		raise UsageError()

	while True:
		logger.info("Waiting for length...")
		l = stdin.readline().strip()
		logger.info("Read '%s' from master", l)
		if not l: break
		request = json.loads(stdin.read(int(l)).decode('utf-8'))
		try:
			command = request[0]
			logger.info("Got request '%s'", command)
			if command == 'select-with-refresh':
				response = do_select_with_refresh(config, options, request[1:])
			response = ['ok', response]
		except SafeException as ex:
			logger.info("Replying with error: %s", ex)
			response = ['error', str(ex)]
		except Exception as ex:
			import traceback
			logger.info("Replying with error: %s", ex)
			response = ['error', traceback.format_exc().strip()]

		data = json.dumps(response).encode('utf-8')
		stdout.write(('%d\n' % len(data)).encode('utf-8'))
		stdout.write(data)
		stdout.flush()
