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
from zeroinstall.zerostore import Store

import json, sys

syntax = ""

if sys.version_info[0] > 2:
	stdin = sys.stdin.buffer
	stdout = sys.stdout.buffer
else:
	stdin = sys.stdin
	stdout = sys.stdout

def add_options(parser):
	pass

def parse_ynm(s):
	if s == 'yes': return True
	if s == 'no': return False
	if s == 'maybe': return None
	assert 0, b

def do_select(config, options, args):
	(for_op, select_opts, reqs_json) = args

	requirements = Requirements(None)
	for k, v in reqs_json.items():
		setattr(requirements, k, v)

	refresh = select_opts['refresh']
	use_gui = parse_ynm(select_opts['use_gui'])
	if select_opts['offline']: config.network_use = model.network_offline # TODO: reenable later?
	config.stores.stores = [Store(d) for d in select_opts['stores']]

	driver = Driver(config = config, requirements = requirements)

	if for_op == 'for-select':
		select_only = True
		download_only = False
	elif for_op == 'for-download':
		select_only = False
		download_only = True
	elif for_op == 'for-run':
		select_only = False
		download_only = False
	else:
		assert 0, for_op

	if use_gui != False:
		# If the user didn't say whether to use the GUI, choose for them.
		gui_args = driver.requirements.get_as_options()
		if download_only:
			# Just changes the button's label
			gui_args.append('--download-only')
		if refresh:
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
		sels = helpers.get_selections_gui(requirements.interface_uri, gui_args, test_callback = None, use_gui = use_gui)

		if not sels:
			return "Aborted"
		elif sels is helpers.DontUseGUI:
			sels = None
	else:
		sels = None

	if sels is None:
		# Note: --download-only also makes us stop and download stale feeds first.
		downloaded = driver.solve_and_download_impls(refresh = refresh, select_only = select_only)
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
			if command == 'select':
				response = do_select(config, options, request[1:])
			else:
				raise SafeException("Unknown command '%s'" % command)
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
