"""
The B{0install slave} command-line interface.
"""

# Copyright (C) 2013, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys, os
import warnings, logging

from zeroinstall import _, logger, SafeException
from zeroinstall.cmd import UsageError
from zeroinstall.injector import model
from zeroinstall.support import tasks
from zeroinstall import support

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

def check_gui():
	"""Returns True if the GUI works, or returns an exception if not."""
	if sys.version_info[0] < 3:
		try:
			import pygtk; pygtk.require('2.0')
		except ImportError as ex:
			logging.info("No GUI available", exc_info = ex)
			return ex

	try:
		if sys.version_info[0] > 2:
			from zeroinstall.gtkui import pygtkcompat
			pygtkcompat.enable()
			pygtkcompat.enable_gtk(version = '3.0')
		import gtk
	except (ImportError, ValueError, RuntimeError) as ex:
		logging.info("No GUI available", exc_info = ex)
		return ex

	if gtk.gdk.get_display() is None:
		return SafeException("Failed to connect to display.")

	return True

_gui_available = None
def gui_is_available():
	global _gui_available
	if _gui_available is None:
		with warnings.catch_warnings():
			_gui_available = check_gui()
	if _gui_available is True:
		return True
	raise _gui_available

def read_chunk():
	l = support.read_bytes(0, 8, null_ok = True)
	logger.debug("Read '%s' from master", l)
	if not l: return None
	return support.read_bytes(0, int(l, 16))

def add_options(parser):
	parser.add_option("-o", "--offline", help=_("try to avoid using the network"), action='store_true')

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

def do_open_app_list_box(ticket):
	gui_is_available()
	from zeroinstall.gtkui.applistbox import AppListBox, AppList
	from zeroinstall.injector.iface_cache import iface_cache
	wait_for_destroy(ticket, AppListBox(iface_cache, AppList()).window)

def do_open_add_box(ticket, uri):
	gui_is_available()
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


def handle_invoke(config, options, ticket, request):
	try:
		command = request[0]
		logger.debug("Got request '%s'", command)
		if command == 'open-app-list-box':
			do_open_app_list_box(ticket)
			return #async
		elif command == 'open-add-box':
			do_open_add_box(ticket, request[1])
			return #async
		else:
			raise SafeException("Internal error: unknown command '%s'" % command)
		#response = ['ok', response]
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

def handle(config, options, args):
	if args:
		raise UsageError()

	if options.offline:
		config.network_use = model.network_offline

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
