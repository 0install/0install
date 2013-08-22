"""
The B{0install slave} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys

from zeroinstall import _, logger, SafeException
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, qdom, selections
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.support import tasks
from zeroinstall.zerostore import Store
from zeroinstall import support

if sys.version_info[0] > 2:
	from io import BytesIO
else:
	from StringIO import StringIO as BytesIO

import json, sys

syntax = ""

if sys.version_info[0] > 2:
	stdin = sys.stdin.buffer
	stdout = sys.stdout.buffer
else:
	stdin = sys.stdin
	stdout = sys.stdout
	if sys.platform == "win32":
		import os, msvcrt
		msvcrt.setmode(stdin.fileno(), os.O_BINARY)
		msvcrt.setmode(stdout.fileno(), os.O_BINARY)

def add_options(parser):
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')

def parse_ynm(s):
	if s == 'yes': return True
	if s == 'no': return False
	if s == 'maybe': return None
	assert 0, b

def reqs_from_json(reqs_json):
	requirements = Requirements(None)
	for k, v in reqs_json.items():
		setattr(requirements, k, v)
	return requirements

def do_download_selections(config, options, args, xml):
	opts, = args
	include_packages = opts['include-packages']

	sels = selections.Selections(xml)
	blocker = sels.download_missing(config, include_packages = include_packages)
	if blocker:
		tasks.wait_for_blocker(blocker)
	return "downloaded"

def do_select(config, options, args):
	(for_op, select_opts, reqs_json) = args

	requirements = reqs_from_json(reqs_json)

	refresh = select_opts['refresh']
	use_gui = parse_ynm(select_opts['use_gui'])

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

def to_json(impl):
	# TODO: for PackageKit candidates, we might need to say how to get them (the Python
	# code adds a retrieval method).
	attrs = {
		'id': impl.id,
		'version': impl.get_version(),
		'machine': impl.machine,
		'is_installed': impl.installed,
		'distro': impl.distro_name,
	}
	if impl.main:
		# We may add a missing 'main' (e.g. host Python) or modify an existing one
		# (e.g. /usr/bin -> /bin).
		attrs['main'] = impl.main
	if impl.quick_test_file:
		attrs['quick-test-file'] = impl.quick_test_file
		if impl.quick_test_mtime:
			attrs['quick-test-mtime'] = str(impl.quick_test_mtime)
	return attrs

class FakeMasterFeed:
	url = None
	package_impls = None
	def get_package_impls(self, distro):
		return self.package_impls

def do_get_package_impls(config, options, args, xml):
	master_feed_url, = args

	master_feed = FakeMasterFeed()
	master_feed.url = master_feed_url

	seen = set()
	results = []

	hosts = []

	# We need the results grouped by <package-implementation> so the OCaml can
	# get the correct attributes and dependencies.
	for elem in xml.childNodes:
		master_feed.package_impls = [(elem, elem.attrs, [])]
		feed = config.iface_cache.distro.get_feed(master_feed)

		impls = [impl for impl in feed.implementations.values() if impl.id not in seen]
		seen.update(feed.implementations.keys())

		hosts += [to_json(impl) for impl in impls
			  if impl.id.startswith('package:host:')]

		results.append([to_json(impl) for impl in impls
				if not impl.id.startswith('package:host:')])

	return [hosts] + results

def do_is_distro_package_installed(config, options, xml):
	id_to_check = xml.attrs['id']
	feed = xml.attrs['from-feed']
	assert feed.startswith('distribution'), feed
	master_url = feed.split(':', 1)[1]
	master_feed = config.iface_cache.get_feed(master_url)
	feed = config.iface_cache.get_feed(master_feed.get_distro_feed())
	return id_to_check in feed.implementations

def send_json(j):
	data = json.dumps(j).encode('utf-8')
	stdout.write(('%d\n' % len(data)).encode('utf-8'))
	stdout.write(data)
	stdout.flush()

def recv_json():
	logger.debug("Waiting for length...")
	l = stdin.readline().strip()
	logger.debug("Read '%s' from master", l)
	if not l:
		sys.stdout = sys.stderr
		return None
	return json.loads(stdin.read(int(l)).decode('utf-8'))

def slave_raw_input(prompt = None):
	send_json(["input", prompt or ""])
	return recv_json()

def handle(config, options, args):
	if args:
		raise UsageError()

	if options.offline:
		config.network_use = model.network_offline

	support.raw_input = slave_raw_input

	while True:
		request = recv_json()
		if request is None: break
		try:
			command = request[0]
			logger.debug("Got request '%s'", command)
			if command == 'select':
				response = do_select(config, options, request[1:])
			elif command == 'download-selections':
				l = stdin.readline().strip()
				xml = qdom.parse(BytesIO(stdin.read(int(l))))
				response = do_download_selections(config, options, request[1:], xml)
			elif command == 'get-package-impls':
				l = stdin.readline().strip()
				xml = qdom.parse(BytesIO(stdin.read(int(l))))
				response = do_get_package_impls(config, options, request[1:], xml)
			elif command == 'is-distro-package-installed':
				l = stdin.readline().strip()
				xml = qdom.parse(BytesIO(stdin.read(int(l))))
				response = do_is_distro_package_installed(config, options, xml)
			else:
				raise SafeException("Internal error: unknown command '%s'" % command)
			response = ['ok', response]
		except SafeException as ex:
			logger.info("Replying with error: %s", ex)
			response = ['error', str(ex)]
		except Exception as ex:
			import traceback
			logger.info("Replying with error: %s", ex)
			response = ['error', traceback.format_exc().strip()]

		send_json(response)
