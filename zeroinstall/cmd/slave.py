"""
The B{0install slave} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys, os

from zeroinstall import _, logger, SafeException
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, qdom, selections, download
from zeroinstall.injector.requirements import Requirements
from zeroinstall.support import tasks
from zeroinstall import support

if sys.version_info[0] > 2:
	from io import BytesIO
else:
	from StringIO import StringIO as BytesIO

import json, sys

syntax = ""

if sys.version_info[0] > 2:
	stdin = sys.stdin.buffer.raw
	stdout = sys.stdout.buffer.raw
else:
	stdin = sys.stdin
	stdout = sys.stdout
	if sys.platform == "win32":
		import os, msvcrt
		msvcrt.setmode(stdin.fileno(), os.O_BINARY)
		msvcrt.setmode(stdout.fileno(), os.O_BINARY)

def read_chunk():
	l = support.read_bytes(0, 8, null_ok = True)
	logger.debug("Read '%s' from master", l)
	if not l: return None
	return support.read_bytes(0, int(l, 16))

def add_options(parser):
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')

def parse_ynm(s):
	if s == 'yes': return True
	if s == 'no': return False
	if s == 'maybe': return None
	assert 0, s

def reqs_from_json(reqs_json):
	requirements = Requirements(None)
	for k, v in reqs_json.items():
		setattr(requirements, k, v)
	return requirements

def do_download_selections(config, options, args, xml):
	opts, = args
	include_packages = opts['include-packages']

	sels = selections.Selections(xml)
	return sels.download_missing(config, include_packages = include_packages)

def to_json(impl):
	attrs = {
		'id': impl.id,
		'version': impl.get_version(),
		'machine': impl.machine,
		'is_installed': impl.installed,
		'distro': impl.distro_name,
	}

	if impl.download_sources:
		m = impl.download_sources[0]
		attrs['retrieval_method'] = {
			'type': 'packagekit',
			'id': m.package_id,
			'size': m.size,
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
	distro_feed = master_feed.get_distro_feed()
	if distro_feed is not None:
		feed = config.iface_cache.get_feed(distro_feed)
		return id_to_check in feed.implementations
	else:
		return False

last_ticket = 0
def take_ticket():
	global last_ticket
	last_ticket += 1
	return str(last_ticket)

def send_json(j):
	data = json.dumps(j).encode('utf-8')
	stdout.write(('%d\n' % len(data)).encode('utf-8'))
	stdout.write(data)
	stdout.flush()

def recv_json():
	logger.debug("Waiting for length...")
	data = read_chunk()
	if not data:
		sys.stdout = sys.stderr
		return None
	data = data.decode('utf-8')
	logger.debug("Read '%s' from master", data)
	return json.loads(data)

pending_replies = {}		# Ticket -> callback function

def handle_message(config, options, message):
	if message[0] == 'invoke':
		ticket, payload = message[1:]
		handle_invoke(config, options, ticket, payload)
	elif message[0] == 'return':
		ticket = message[1]
		value = message[2]
		cb = pending_replies[ticket]
		del pending_replies[ticket]
		cb(value)
	else:
		assert 0, message

def do_get_distro_candidates(config, args, xml):
	master_feed_url, = args

	master_feed = FakeMasterFeed()
	master_feed.url = master_feed_url
	master_feed.package_impls = [(elem, elem.attrs, []) for elem in xml.childNodes]

	return config.iface_cache.distro.fetch_candidates(master_feed)

@tasks.async
def do_download_and_import_feed(config, ticket, args):
	try:
		if gui_driver is not None: config = gui_driver.config
		feed_url, = args
		blocker = config.fetcher.download_and_import_feed(feed_url)
		if blocker:
			yield blocker
			tasks.check(blocker)
		send_json(["return", ticket, ["ok", "success"]])
	except download.DownloadAborted as ex:
		send_json(["return", ticket, ["ok", "aborted-by-user"]])
	except Exception as ex:
		send_json(["return", ticket, ["error", str(ex)]])

@tasks.async
def reply_when_done(ticket, blocker):
	try:
		if blocker:
			yield blocker
			tasks.check(blocker)
		send_json(["return", ticket, ["ok", []]])
	except Exception as ex:
		logger.info("async task failed", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

def do_notify_user(config, args):
	from zeroinstall.injector import background
	handler = background.BackgroundHandler()
	handler.notify(args["title"], args["message"], timeout = args["timeout"])

def do_check_gui(use_gui):
	from zeroinstall.gui import main

	if use_gui == "yes": use_gui = True
	elif use_gui == "no": return False
	elif use_gui == "maybe": use_gui = None
	else: assert 0, use_gui

	return main.gui_is_available(use_gui)

def do_report_error(config, msg):
	if gui_driver is not None: config = gui_driver.config
	config.handler.report_error(SafeException(msg))

run_gui = None			# Callback to invoke when a full solve-with-downloads is done
gui_driver = None		# Object to notify about each new set of selections

def do_open_gui(args):
	global run_gui, gui_driver
	assert run_gui is None

	reqs, opts = args

	gui_args = []

	if opts['refresh']: gui_args += ['--refresh']
	if opts['systray']: gui_args += ['--systray']

	if opts['action'] == 'for-select': gui_args += ['--select-only']
	elif opts['action'] == 'for-download': gui_args += ['--download-only']
	elif opts['action'] != 'for-run': assert 0, opts

	reqs = reqs_from_json(reqs)
	gui_args += reqs.get_as_options()

	from zeroinstall.gui import main
	run_gui, gui_driver = main.open_gui(gui_args + ['--', reqs.interface_uri])
	return []

@tasks.async
def do_run_gui(ticket):
	reply_holder = []
	blocker = run_gui(reply_holder)
	try:
		if blocker:
			yield blocker
			tasks.check(blocker)
		reply, = reply_holder
		send_json(["return", ticket, ["ok", reply]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

def do_wait_for_network(config):
	from zeroinstall.injector import background
	_NetworkState = background._NetworkState
	background_handler = background.BackgroundHandler()

	network_state = background_handler.get_network_state()

	if 'ZEROINSTALL_TEST_BACKGROUND' in os.environ: return

	if network_state not in (_NetworkState.NM_STATE_CONNECTED_SITE, _NetworkState.NM_STATE_CONNECTED_GLOBAL):
		logger.info(_("Not yet connected to network (status = %d). Sleeping for a bit..."), network_state)
		import time
		time.sleep(120)
		if network_state in (_NetworkState.NM_STATE_DISCONNECTED, _NetworkState.NM_STATE_ASLEEP):
			logger.info(_("Still not connected to network. Giving up."))
			return "offline"
		return "online"
	else:
		logger.info(_("NetworkManager says we're on-line. Good!"))
		return "online"

def do_gui_update_selections(args, xml):
	ready, tree = args
	gui_driver.set_selections(ready, tree, xml)

def handle_invoke(config, options, ticket, request):
	try:
		command = request[0]
		logger.debug("Got request '%s'", command)
		if command == 'open-gui':
			response = do_open_gui(request[1:])
		elif command == 'run-gui':
			do_run_gui(ticket)
			return #async
		elif command == 'wait-for-network':
			response = do_wait_for_network(config)
		elif command == 'check-gui':
			response = do_check_gui(request[1])
		elif command == 'report-error':
			response = do_report_error(config, request[1])
		elif command == 'gui-update-selections':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_gui_update_selections(request[1:], xml)
		elif command == 'download-selections':
			xml = qdom.parse(BytesIO(read_chunk()))
			blocker = do_download_selections(config, options, request[1:], xml)
			reply_when_done(ticket, blocker)
			return #async
		elif command == 'get-package-impls':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_get_package_impls(config, options, request[1:], xml)
		elif command == 'is-distro-package-installed':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_is_distro_package_installed(config, options, xml)
		elif command == 'get-distro-candidates':
			xml = qdom.parse(BytesIO(read_chunk()))
			blocker = do_get_distro_candidates(config, request[1:], xml)
			reply_when_done(ticket, blocker)
			return	# async
		elif command == 'download-and-import-feed':
			do_download_and_import_feed(config, ticket, request[1:])
			return	# async
		elif command == 'notify-user':
			response = do_notify_user(config, request[1])
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

	send_json(["return", ticket, response])

def resolve_on_reply(ticket, blocker):
	def done(details):
		if details[0] == 'ok':
			blocker.result = details[1]
			blocker.trigger()
		else:
			blocker.trigger(exception = (SafeException(details[1]), None))
	pending_replies[ticket] = done

# Get the details needed for the GUI component dialog
def get_component_details(interface_uri):
	ticket = take_ticket()
	blocker = tasks.Blocker('get_component_details')
	resolve_on_reply(ticket, blocker)
	send_json(["invoke", ticket, ["get-component-details", interface_uri]])
	return blocker

def justify_decision(iface, feed, impl_id):
	ticket = take_ticket()
	blocker = tasks.Blocker('justify_decision')
	resolve_on_reply(ticket, blocker)
	send_json(["invoke", ticket, ["justify-decision", iface, feed, impl_id]])
	return blocker

def get_bug_report_details():
	ticket = take_ticket()
	blocker = tasks.Blocker('get_bug_report_details')
	resolve_on_reply(ticket, blocker)
	send_json(["invoke", ticket, ["get-bug-report-details"]])
	return blocker

def run_test():
	ticket = take_ticket()
	blocker = tasks.Blocker('run_test')
	resolve_on_reply(ticket, blocker)
	send_json(["invoke", ticket, ["run-test"]])
	return blocker

def handle(config, options, args):
	if args:
		raise UsageError()

	if options.offline:
		config.network_use = model.network_offline

	def slave_raw_input(prompt = ""):
		ticket = take_ticket()
		send_json(["invoke", ticket, ["input", prompt]])
		while True:
			message = recv_json()
			if message[0] == 'return' and message[1] == ticket:
				reply = message[2]
				assert reply[0] == 'ok', reply
				return reply[1]
			else:
				handle_message(config, options, message)

	support.raw_input = slave_raw_input

	@tasks.async
	def handle_events():
		while True:
			logger.debug("waiting for stdin")
			yield tasks.InputBlocker(stdin, 'wait for commands from master')
			logger.debug("reading JSON")
			message = recv_json()
			logger.debug("got %s", message)
			if message is None: break
			handle_message(config, options, message)

	tasks.wait_for_blocker(handle_events())
