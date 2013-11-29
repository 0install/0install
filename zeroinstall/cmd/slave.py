"""
The B{0install slave} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys, os, collections

from zeroinstall import _, logger, SafeException
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model, qdom, download, gpg
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
sys.stdout = sys.stderr

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

@tasks.async
def do_confirm(config, ticket, options, message):
	if gui_driver is not None: config = gui_driver.config
	try:
		confirm = config.handler.confirm(message)
		yield confirm
		tasks.check(confirm)

		send_json(["return", ticket, ["ok", "ok"]])
	except download.DownloadAborted as ex:
		send_json(["return", ticket, ["ok", "cancel"]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

@tasks.async
def do_run_preferences(config, ticket):
	try:
		from zeroinstall.gui import preferences
		box = preferences.show_preferences(config)
		done = tasks.Blocker('close preferences')
		box.connect('destroy', lambda w: done.trigger())
		yield done
		tasks.check(done)

		send_json(["return", ticket, ["ok", None]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

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

class OCamlDownload:
	url = None
	hint = None
	sofar = 0
	expected_size = None
	tempfile = None
	status = download.download_fetching
	downloaded = None
	_final_total_size = None

	def get_current_fraction(self):
		"""Returns the current fraction of this download that has been fetched (from 0 to 1),
		or None if the total size isn't known. Note that the timeout does not stop the download;
		we just use it as a signal to try a mirror in parallel.
		@return: fraction downloaded
		@rtype: int | None"""
		if self.tempfile is None:
			return 1
		if self.expected_size is None:
			return None		# Unknown
		current_size = self.get_bytes_downloaded_so_far()
		return float(current_size) / self.expected_size

	def get_bytes_downloaded_so_far(self):
		"""Get the download progress. Will be zero if the download has not yet started.
		@rtype: int"""
		return self.sofar

	def abort(self):
		invoke_master(["abort-download", self.tempfile])

downloads = {}
def do_start_monitoring(config, details):
	if gui_driver is not None: config = gui_driver.config
	size = details["size"]
	if size is not None:
		size = int(size)
	dl = OCamlDownload()
	dl.url = details["url"]
	dl.hint = details["hint"]
	dl.expected_size = size
	dl.tempfile = details["tempfile"]
	dl.downloaded = tasks.Blocker("Download '%s'" % details["url"])
	downloads[dl.tempfile] = dl
	config.handler.monitor_download(dl)

def do_set_progress(config, tmpfile, sofar, expected_size):
	dl = downloads[tmpfile]
	dl.sofar = int(sofar)
	if expected_size:
		dl.expected_size = int(expected_size)

def do_stop_monitoring(config, tmpfile):
	dl = downloads[tmpfile]
	dl.status = download.download_complete
	dl._final_total_size = dl.get_bytes_downloaded_so_far()
	dl.downloaded.trigger()
	del downloads[tmpfile]

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

	root_uri, opts = args

	gui_args = []

	if opts['refresh']: gui_args += ['--refresh']
	if opts['systray']: gui_args += ['--systray']

	if opts['action'] == 'for-select': gui_args += ['--select-only']
	elif opts['action'] == 'for-download': gui_args += ['--download-only']
	elif opts['action'] != 'for-run': assert 0, opts

	from zeroinstall.gui import main
	run_gui, gui_driver = main.open_gui(gui_args + ['--', root_uri])
	return []

def do_open_app_list_box(ticket):
	from zeroinstall.gui import main
	main.gui_is_available(True)
	from zeroinstall.gtkui.applistbox import AppListBox, AppList
	from zeroinstall.injector.iface_cache import iface_cache
	wait_for_destroy(ticket, AppListBox(iface_cache, AppList()).window)

def do_open_add_box(ticket, uri):
	from zeroinstall.gui import main
	main.gui_is_available(True)
	from zeroinstall.gtkui.addbox import AddBox
	wait_for_destroy(ticket, AddBox(uri).window)

@tasks.async
def wait_for_destroy(ticket, window):
	window.show()
	blocker = tasks.Blocker("window closed")
	window.connect('destroy', lambda *args: blocker.trigger())
	try:
		if blocker:
			yield blocker
			tasks.check(blocker)
		send_json(["return", ticket, ["ok", None]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

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

cache_explorer = None

@tasks.async
def do_open_cache_explorer(config, ticket):
	global cache_explorer
	assert cache_explorer is None
	try:
		from zeroinstall.gui import main
		main.gui_is_available(True)		# Will throw if not

		blocker = tasks.Blocker("Cache explorer window")
		import gtk
		from zeroinstall.gtkui import cache
		cache_explorer = cache.CacheExplorer(config)
		cache_explorer.window.connect('destroy', lambda widget: blocker.trigger())
		cache_explorer.show()
		gtk.gdk.flush()
		yield blocker
		tasks.check(blocker)
		send_json(["return", ticket, ["ok", None]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

def do_populate_cache_explorer(ok_feeds, error_feeds, unowned):
	return cache_explorer.populate_model(ok_feeds, error_feeds, unowned)

def do_gui_update_selections(args, xml):
	ready, tree = args
	gui_driver.set_selections(ready, tree, xml)

def handle_invoke(config, options, ticket, request):
	try:
		command = request[0]
		logger.debug("Got request '%s'", command)
		if command == 'open-gui':
			response = do_open_gui(request[1:])
		elif command == 'ping':
			response = None
		elif command == 'open-cache-explorer':
			do_open_cache_explorer(config, ticket)
			return #async
		elif command == 'populate-cache-explorer':
			response = do_populate_cache_explorer(*request[1:])
		elif command == 'run-gui':
			do_run_gui(ticket)
			return #async
		elif command == 'open-app-list-box':
			do_open_app_list_box(ticket)
			return #async
		elif command == 'open-add-box':
			do_open_add_box(ticket, request[1])
			return #async
		elif command == 'check-gui':
			response = do_check_gui(request[1])
		elif command == 'report-error':
			response = do_report_error(config, request[1])
		elif command == 'gui-update-selections':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_gui_update_selections(request[1:], xml)
		elif command == 'confirm':
			do_confirm(config, ticket, options, request[1])
			return
		elif command == 'start-monitoring':
			response = do_start_monitoring(config, request[1])
		elif command == 'set-progress':
			response = do_set_progress(config, *request[1:])
		elif command == 'stop-monitoring':
			response = do_stop_monitoring(config, request[1])
		elif command == 'run-preferences':
			do_run_preferences(config, ticket)
			return
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

def invoke_master(request):
	ticket = take_ticket()
	blocker = tasks.Blocker(request[0])
	resolve_on_reply(ticket, blocker)
	send_json(["invoke", ticket, request])
	return blocker

# Get the details needed for the GUI component dialog
def get_component_details(interface_uri):
	return invoke_master(["get-component-details", interface_uri])

def get_feed_description(feed_url):
	return invoke_master(["get-feed-description", feed_url])

def justify_decision(iface, feed, impl_id):
	return invoke_master(["justify-decision", iface, feed, impl_id])

def get_bug_report_details():
	return invoke_master(["get-bug-report-details"])

def run_test():
	return invoke_master(["run-test"])

def download_archives():
	return invoke_master(["download-archives"])

def add_remote_feed(iface, url):
	return invoke_master(["add-remote-feed", iface, url])

def add_local_feed(iface, url):
	return invoke_master(["add-local-feed", iface, url])

def remove_feed(iface, url):
	return invoke_master(["remove-feed", iface, url])

def handle(config, options, args):
	if args:
		raise UsageError()

	if options.offline:
		config.network_use = model.network_offline

	if options.dry_run:
		config.handler.dry_run = True

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
