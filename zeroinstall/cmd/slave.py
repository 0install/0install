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
from zeroinstall.injector.distro import get_host_distribution
from zeroinstall.support import tasks
from zeroinstall import support

if sys.version_info[0] > 2:
	from io import BytesIO
else:
	from StringIO import StringIO as BytesIO

import json, sys

syntax = ""

_distro = None
def get_distro():
	global _distro
	if _distro is None:
		_distro = get_host_distribution()
	return _distro

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

def get_dry_run_names(config):
	paths = set()
	if config.handler.dry_run:
		for store in config.stores.stores:
			for name in store.dry_run_names:
				paths.add(os.path.join(store.dir, name))
	return paths

@tasks.async
def do_confirm_distro_install(config, ticket, options, impls):
	if gui_driver is not None: config = gui_driver.config
	try:
		manual_impls = [impl['id'] for impl in impls if not impl['needs-confirmation']]
		unsafe_impls = [impl for impl in impls if impl['needs-confirmation']]

		if unsafe_impls:
			confirm = config.handler.confirm_install(_('The following components need to be installed using native packages. '
				'These come from your distribution, and should therefore be trustworthy, but they also '
				'run with extra privileges. In particular, installing them may run extra services on your '
				'computer or affect other users. You may be asked to enter a password to confirm. The '
				'packages are:\n\n') + ('\n'.join('- ' + x['id'] for x in unsafe_impls)))
			yield confirm
			tasks.check(confirm)

		if manual_impls:
			raise model.SafeException(_("This program depends on '%s', which is a package that is available through your distribution. "
					"Please install it manually using your distribution's tools and try again. Or, install 'packagekit' and I can "
					"use that to install it.") % manual_impls[0])

		blockers = []
		for impl in unsafe_impls:
			from zeroinstall.injector import packagekit
			packagekit_id = impl['packagekit-id']
			pk = get_distro().packagekit.pk
			dl = packagekit.PackageKitDownload('packagekit:' + packagekit_id, hint = impl['master-feed'],
					pk = pk, packagekit_id = packagekit_id, expected_size = int(impl['size']))
			config.handler.monitor_download(dl)
			blockers.append(dl.downloaded)

		# Record the first error log the rest
		error = []
		def dl_error(ex, tb = None):
			if error:
				config.handler.report_error(ex)
			else:
				error.append((ex, tb))
		while blockers:
			yield blockers
			tasks.check(blockers, dl_error)
			blockers = [b for b in blockers if not b.happened]
		if error:
			from zeroinstall import support
			support.raise_with_traceback(*error[0])

		send_json(["return", ticket, ["ok", "ok"]])
	except download.DownloadAborted as ex:
		send_json(["return", ticket, ["ok", "aborted-by-user"]])
	except Exception as ex:
		logger.warning("Returning error", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

def do_add_manifest_and_verify(config, options, args):
	from zeroinstall.zerostore import manifest
	required_digest, tmpdir = args
	manifest.fixup_permissions(tmpdir)
	alg, required_value = manifest.splitID(required_digest)
	actual_digest = alg.getID(manifest.add_manifest_file(tmpdir, alg))
	if actual_digest != required_digest:
		raise manifest.BadDigest(_('Incorrect manifest -- archive is corrupted.\n'
				'Required digest: %(required_digest)s\n'
				'Actual digest: %(actual_digest)s\n') %
				{'required_digest': required_digest, 'actual_digest': actual_digest})


def do_unpack_archive(config, options, details):
	from zeroinstall.zerostore import unpack

	with open(details['tmpfile'], 'rb') as stream:
		unpack.unpack_archive('unused', stream, details['destdir'],
				extract = details['extract'],
				type = details['mime_type'],
				start_offset = int(details['start_offset']))

def to_json(impl):
	attrs = {
		'id': impl.id,
		'version': impl.get_version(),
		'machine': impl.machine,
		'is_installed': impl.installed,
		'distro': impl.distro_name,
	}

	if impl.download_sources:
		feed = impl.feed.url
		assert feed.startswith("distribution:"), feed
		master_feed = feed.split(':', 1)[1]
		m = impl.download_sources[0]
		attrs['retrieval_method'] = {
			'type': 'packagekit',
			'id': m.package_id,
			'packagekit-id': m.packagekit_id,
			'size': float(m.size),		# Use floats to avoid 31-bit int problem
			'master-feed': master_feed,

			# True => ask user to confirm, then install with PackageKit
			# False => tell user to install package manually
			'needs-confirmation': m.needs_confirmation,
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

def do_get_package_impls(config, options, args, xml):
	master_feed_url, = args

	seen = set()
	results = []

	hosts = []

	# We need the results grouped by <package-implementation> so the OCaml can
	# get the correct attributes and dependencies.
	for elem in xml.childNodes:
		package_impls = [(elem, elem.attrs, [])]
		feed = get_distro().get_feed(master_feed_url, package_impls)

		impls = [impl for impl in feed.implementations.values() if impl.id not in seen]
		seen.update(feed.implementations.keys())

		hosts += [to_json(impl) for impl in impls
			  if impl.id.startswith('package:host:')]

		results.append([to_json(impl) for impl in impls
				if not impl.id.startswith('package:host:')])

	return [hosts] + results

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

	package_impls = [(elem, elem.attrs, []) for elem in xml.childNodes]

	return get_distro().fetch_candidates(package_impls)

PendingFromOCaml = collections.namedtuple("PendingFromOCaml", ["url", "sigs"])

class OCamlKeyInfo:
	info = []
	blocker = None
	status = "Fetching key information ..."

pending_key_info = {}		# Fingerprint -> OCamlKeyInfo

@tasks.async
def do_update_key_info(config, ticket, fingerprint, xml):
	try:
		ki = pending_key_info.get(fingerprint, None)
		if ki:
			from xml.dom import minidom
			doc = minidom.parseString(qdom.to_UTF8(xml))
			ki.info = doc.documentElement.childNodes
			ki.blocker.trigger()
			ki.blocker = None
		else:
			logger.info("Unexpected key info for %s (not in %s)", fingerprint, pending_key_info)
	except Exception as ex:
		logger.warning("do_update_key_info", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

@tasks.async
def do_confirm_keys(config, ticket, url, xml):
	try:
		if gui_driver is not None: config = gui_driver.config
		fingerprints = []
		#valid_sigs = [ for (fingerprint, info) in infos]
		pending = PendingFromOCaml(url = url, sigs = [])

		global pending_key_info
		pending_key_info = {}
		key_infos = {}
		for result in xml.childNodes:
			fingerprint = result.attrs['fingerprint']
			fingerprints.append(fingerprint)
			sig = gpg.ValidSig([fingerprint, None, 0])
			ki = OCamlKeyInfo()
			if 'pending' in result.attrs:
				ki.blocker = tasks.Blocker("Getting info for key '%s'" % fingerprint)
			elif 'error' in result.attrs:
				from xml.dom import minidom
				doc = minidom.parseString('<item vote="bad"/>')
				root = doc.documentElement
				root.appendChild(doc.createTextNode(_('Error getting key information: %s') % result.attrs['error']))
				ki.info = [root]
			else:
				from xml.dom import minidom
				doc = minidom.parseString(qdom.to_UTF8(result))
				ki.info = doc.documentElement.childNodes
			key_infos[sig] = ki
			pending_key_info[fingerprint] = ki

		confirmed_keys = []
		blocker = config.handler.confirm_import_feed(pending, key_infos, confirmed_keys)
		if blocker:
			yield blocker
			tasks.check(blocker)

		send_json(["return", ticket, ["ok", confirmed_keys]])
	except Exception as ex:
		logger.warning("do_confirm_keys", exc_info = True)
		send_json(["return", ticket, ["error", str(ex)]])

def assert_manifest(required, tmpdir):
	from zeroinstall.zerostore import manifest
	alg_name = required.split('=', 1)[0]
	manifest.fixup_permissions(tmpdir)

	sha1 = alg_name + '=' + manifest.add_manifest_file(tmpdir, manifest.get_algorithm(alg_name)).hexdigest()
	assert sha1 == required

	# Check permissions are sensible
	for root, dirs, files in os.walk(tmpdir):
		for f in files + dirs:
			full = os.path.join(root, f)
			if os.path.islink(full): continue
			full_mode = os.stat(full).st_mode
			assert 0o444 == full_mode & 0o666	# Must be r-?r-?r-?

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

class OCamlDownload:
	url = None
	hint = None
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
		if self.status is download.download_fetching:
			return os.stat(self.tempfile).st_size
		else:
			return self._final_total_size or 0

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

class DummyPackageKit:
	available = False
	def get_candidates(self, package, factory, prefix): pass

def do_test_distro(config, name, args):
	global _distro
	from zeroinstall.injector import distro
	cons = getattr(distro, name)
	_distro = cons(*args)
	_distro._packagekit = DummyPackageKit()

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
		elif command == 'wait-for-network':
			response = do_wait_for_network(config)
		elif command == 'check-gui':
			response = do_check_gui(request[1])
		elif command == 'report-error':
			response = do_report_error(config, request[1])
		elif command == 'gui-update-selections':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_gui_update_selections(request[1:], xml)
		elif command == 'confirm-distro-install':
			blocker = do_confirm_distro_install(config, ticket, options, request[1])
			return
		elif command == 'add-manifest-and-verify':
			response = do_add_manifest_and_verify(config, options, request[1:])
		elif command == 'utime':
			t = request[2]
			os.utime(request[1], (t, t))
			response = None
		elif command == 'unpack-archive':
			response = do_unpack_archive(config, options, request[1])
		elif command == 'get-package-impls':
			xml = qdom.parse(BytesIO(read_chunk()))
			response = do_get_package_impls(config, options, request[1:], xml)
		elif command == 'get-distro-candidates':
			xml = qdom.parse(BytesIO(read_chunk()))
			blocker = do_get_distro_candidates(config, request[1:], xml)
			reply_when_done(ticket, blocker)
			return	# async
		elif command == 'confirm-keys':
			xml = qdom.parse(BytesIO(read_chunk()))
			do_confirm_keys(config, ticket, request[1], xml)
			return	# async
		elif command == 'update-key-info':
			xml = qdom.parse(BytesIO(read_chunk()))
			do_update_key_info(config, ticket, request[1], xml)
			return	# async
		elif command == 'assert-manifest':
			response = assert_manifest(*request[1:])
		elif command == 'notify-user':
			response = do_notify_user(config, request[1])
		elif command == 'start-monitoring':
			response = do_start_monitoring(config, request[1])
		elif command == 'stop-monitoring':
			response = do_stop_monitoring(config, request[1])
		elif command == 'test-distro':
			response = do_test_distro(config, request[1], request[2])
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

def start_timeout(timeout):
	return invoke_master(["start-timeout", timeout])

def handle(config, options, args):
	if args:
		raise UsageError()

	if options.offline:
		config.network_use = model.network_offline

	if options.dry_run:
		config.handler.dry_run = True

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
