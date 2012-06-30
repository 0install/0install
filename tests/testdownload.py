#!/usr/bin/env python
from __future__ import with_statement
from basetest import BaseTest
import sys, tempfile, os
if sys.version_info[0] > 2:
	from io import StringIO
else:
	from StringIO import StringIO
import unittest, signal
from logging import getLogger, WARN, ERROR
from contextlib import contextmanager

sys.path.insert(0, '..')

os.environ["http_proxy"] = "localhost:8000"

from zeroinstall import helpers
from zeroinstall.injector import model, gpg, download, trust, background, arch, selections, qdom, run
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.zerostore import Store, NotStored; Store._add_with_helper = lambda *unused: False
from zeroinstall.support import basedir, tasks, ro_rmtree
from zeroinstall.injector import fetch
import data
import my_dbus

import server

ran_gui = False
def raise_gui(*args):
	global ran_gui
	ran_gui = True
background._detach = lambda: False

local_hello = """<?xml version="1.0" ?>
<selections command="run" interface="http://example.com:8000/Hello.xml" xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <selection id="." local-path='.' interface="http://example.com:8000/Hello.xml" version="0.1"><command name="run" path="foo"/></selection>
</selections>"""

@contextmanager
def output_suppressed():
	old_stdout = sys.stdout
	old_stderr = sys.stderr
	try:
		sys.stdout = StringIO()
		sys.stderr = StringIO()
		try:
			yield
		except Exception:
			raise
		except BaseException as ex:
			# Don't abort unit-tests if someone raises SystemExit
			raise Exception(str(type(ex)) + " " + str(ex))
	finally:
		sys.stdout = old_stdout
		sys.stderr = old_stderr

@contextmanager
def trapped_exit(expected_exit_status):
	pid = os.getpid()
	old_exit = os._exit
	def my_exit(code):
		# The background handler runs in the same process
		# as the tests, so don't let it abort.
		if os.getpid() == pid:
			raise SystemExit(code)
		# But, child download processes are OK
		old_exit(code)
	os._exit = my_exit
	try:
		try:
			yield
			assert False
		except SystemExit as ex:
			assert ex.code == expected_exit_status
	finally:
		os._exit = old_exit

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

def download_and_execute(driver, prog_args, main = None):
	driver_download(driver)
	run.execute_selections(driver.solver.selections, prog_args, stores = driver.config.stores, main = main)

def driver_download(driver):
	downloaded = driver.solve_and_download_impls()
	if downloaded:
		tasks.wait_for_blocker(downloaded)

class NetworkManager:
	def state(self):
		return 3	# NM_STATUS_CONNECTED

server_process = None
def kill_server_process():
	global server_process
	if server_process is not None:
		# The process may still be running.  See
		# http://bugs.python.org/issue14252 for why this is so
		# complicated.
		server_process.stdout.close()
		if os.name != 'nt':
			server_process.kill()
		else:
			try:
				server_process.kill()
			except WindowsError as e:
				# This is what happens when terminate
				# is called after the process has died.
				if e.winerror == 5 and e.strerror == 'Access is denied':
					assert not server_process.poll()
				else:
					raise
		server_process.wait()
		server_process = None

def run_server(*args):
	global server_process
	assert server_process is None
	server_process = server.handle_requests(*args)

real_get_selections_gui = helpers.get_selections_gui

class TestDownload(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.config.handler.allow_downloads = True
		self.config.key_info_server = 'http://localhost:3333/key-info'

		self.config.fetcher = fetch.Fetcher(self.config)

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		stream.close()

		trust.trust_db.watchers = []

		helpers.get_selections_gui = raise_gui

		global ran_gui
		ran_gui = False

	def tearDown(self):
		helpers.get_selections_gui = real_get_selections_gui
		BaseTest.tearDown(self)
		kill_server_process()

	def testRejectKey(self):
		with output_suppressed():
			run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			driver = Driver(requirements = Requirements('http://localhost:8000/Hello'), config = self.config)
			assert driver.need_download()
			sys.stdin = Reply("N\n")
			try:
				download_and_execute(driver, ['Hello'])
				assert 0
			except model.SafeException as ex:
				if "has no usable implementations" not in str(ex):
					raise ex
				if "Not signed with a trusted key" not in str(self.config.handler.ex):
					raise self.config.handler.ex
				self.config.handler.ex = None

	def testRejectKeyXML(self):
		with output_suppressed():
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			driver = Driver(requirements = Requirements('http://example.com:8000/Hello.xml'), config = self.config)
			assert driver.need_download()
			sys.stdin = Reply("N\n")
			try:
				download_and_execute(driver, ['Hello'])
				assert 0
			except model.SafeException as ex:
				if "has no usable implementations" not in str(ex):
					raise ex
				if "Not signed with a trusted key" not in str(self.config.handler.ex):
					raise
				self.config.handler.ex = None
	
	def testImport(self):
		from zeroinstall.injector import cli

		rootLogger = getLogger()
		rootLogger.disabled = True
		try:
			try:
				cli.main(['--import', '-v', 'NO-SUCH-FILE'], config = self.config)
				assert 0
			except model.SafeException as ex:
				assert 'NO-SUCH-FILE' in str(ex)
		finally:
			rootLogger.disabled = False
			rootLogger.setLevel(WARN)

		hello = self.config.iface_cache.get_feed('http://localhost:8000/Hello')
		self.assertEqual(None, hello)

		with output_suppressed():
			run_server('6FCF121BE2390E0B.gpg')
			sys.stdin = Reply("Y\n")

			assert not trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')
			cli.main(['--import', 'Hello'], config = self.config)
			assert trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')

			# Check we imported the interface after trusting the key
			hello = self.config.iface_cache.get_feed('http://localhost:8000/Hello', force = True)
			self.assertEqual(1, len(hello.implementations))

			self.assertEqual(None, hello.local_path)

			# Shouldn't need to prompt the second time
			sys.stdin = None
			cli.main(['--import', 'Hello'], config = self.config)

	def testSelections(self):
		from zeroinstall.injector import cli
		with open("selections.xml", 'rb') as stream:
			root = qdom.parse(stream)
		sels = selections.Selections(root)
		class Options: dry_run = False

		with output_suppressed():
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")
			try:
				self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
				assert False
			except NotStored:
				pass
			cli.main(['--download-only', 'selections.xml'], config = self.config)
			path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

			assert sels.download_missing(self.config) is None

	def testHelpers(self):
		from zeroinstall import helpers

		with output_suppressed():
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")
			sels = helpers.ensure_cached('http://example.com:8000/Hello.xml', config = self.config)
			path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))
			assert sels.download_missing(self.config) is None

	def testSelectionsWithFeed(self):
		from zeroinstall.injector import cli
		with open("selections.xml", 'rb') as stream:
			root = qdom.parse(stream)
		sels = selections.Selections(root)

		with output_suppressed():
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")

			tasks.wait_for_blocker(self.config.fetcher.download_and_import_feed('http://example.com:8000/Hello.xml', self.config.iface_cache))

			cli.main(['--download-only', 'selections.xml'], config = self.config)
			path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

			assert sels.download_missing(self.config) is None
	
	def testAcceptKey(self):
		with output_suppressed():
			run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			driver = Driver(requirements = Requirements('http://localhost:8000/Hello'), config = self.config)
			assert driver.need_download()
			sys.stdin = Reply("Y\n")
			try:
				download_and_execute(driver, ['Hello'], main = 'Missing')
				assert 0
			except model.SafeException as ex:
				if "HelloWorld/Missing" not in str(ex):
					raise
	
	def testAutoAcceptKey(self):
		self.config.auto_approve_keys = True
		with output_suppressed():
			run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			driver = Driver(requirements = Requirements('http://localhost:8000/Hello'), config = self.config)
			assert driver.need_download()
			sys.stdin = Reply("")
			try:
				download_and_execute(driver, ['Hello'], main = 'Missing')
				assert 0
			except model.SafeException as ex:
				if "HelloWorld/Missing" not in str(ex):
					raise

	def testDistro(self):
		with output_suppressed():
			native_url = 'http://example.com:8000/Native.xml'

			# Initially, we don't have the feed at all...
			master_feed = self.config.iface_cache.get_feed(native_url)
			assert master_feed is None, master_feed

			trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
			run_server('Native.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			driver = Driver(requirements = Requirements(native_url), config = self.config)
			assert driver.need_download()

			solve = driver.solve_with_downloads()
			tasks.wait_for_blocker(solve)
			tasks.check(solve)

			master_feed = self.config.iface_cache.get_feed(native_url)
			assert master_feed is not None
			assert master_feed.implementations == {}

			distro_feed_url = master_feed.get_distro_feed()
			assert distro_feed_url is not None
			distro_feed = self.config.iface_cache.get_feed(distro_feed_url)
			assert distro_feed is not None
			assert len(distro_feed.implementations) == 2, distro_feed.implementations

	def testWrongSize(self):
		with output_suppressed():
			run_server('Hello-wrong-size', '6FCF121BE2390E0B.gpg',
							'/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			driver = Driver(requirements = Requirements('http://localhost:8000/Hello-wrong-size'), config = self.config)
			assert driver.need_download()
			sys.stdin = Reply("Y\n")
			try:
				download_and_execute(driver, ['Hello'], main = 'Missing')
				assert 0
			except model.SafeException as ex:
				if "Downloaded archive has incorrect size" not in str(ex):
					raise ex

	def testRecipe(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			run_server(('HelloWorld.tar.bz2', 'redirect/dummy_1-1_all.deb', 'dummy_1-1_all.deb'))
			driver = Driver(requirements = Requirements(os.path.abspath('Recipe.xml')), config = self.config)
			try:
				download_and_execute(driver, [])
				assert False
			except model.SafeException as ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out
	
	def testRename(self):
		with output_suppressed():
			run_server(('HelloWorld.tar.bz2',))
			requirements = Requirements(os.path.abspath('RecipeRename.xml'))
			requirements.command = None
			driver = Driver(requirements = requirements, config = self.config)
			driver_download(driver)
			digests = driver.solver.selections[requirements.interface_uri].digests
			path = self.config.stores.lookup_any(digests)
			assert os.path.exists(os.path.join(path, 'HelloUniverse', 'minor'))
			assert not os.path.exists(os.path.join(path, 'HelloWorld'))
			assert not os.path.exists(os.path.join(path, 'HelloUniverse', 'main'))

	def testSymlink(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			run_server(('HelloWorld.tar.bz2', 'HelloSym.tgz'))
			driver = Driver(requirements = Requirements(os.path.abspath('RecipeSymlink.xml')), config = self.config)
			try:
				download_and_execute(driver, [])
				assert False
			except model.SafeException as ex:
				if 'Attempt to unpack dir over symlink "HelloWorld"' not in str(ex):
					raise
			self.assertEqual(None, basedir.load_first_cache('0install.net', 'implementations', 'main'))
		finally:
			sys.stdout = old_out

	def testAutopackage(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			run_server('HelloWorld.autopackage')
			driver = Driver(requirements = Requirements(os.path.abspath('Autopackage.xml')), config = self.config)
			try:
				download_and_execute(driver, [])
				assert False
			except model.SafeException as ex:
				if "HelloWorld/Missing" not in str(ex):
					raise
		finally:
			sys.stdout = old_out

	def testRecipeFailure(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			run_server('*')
			driver = Driver(requirements = Requirements(os.path.abspath('Recipe.xml')), config = self.config)
			try:
				download_and_execute(driver, [])
				assert False
			except download.DownloadError as ex:
				if "Connection" not in str(ex):
					raise
		finally:
			sys.stdout = old_out

	def testMirrors(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			getLogger().setLevel(ERROR)
			trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
			run_server(server.Give404('/Hello.xml'),
					'/0mirror/feeds/http/example.com:8000/Hello.xml/latest.xml',
					'/0mirror/keys/6FCF121BE2390E0B.gpg')
			driver = Driver(requirements = Requirements('http://example.com:8000/Hello.xml'), config = self.config)
			self.config.feed_mirror = 'http://example.com:8000/0mirror'

			refreshed = driver.solve_with_downloads()
			tasks.wait_for_blocker(refreshed)
			assert driver.solver.ready
		finally:
			sys.stdout = old_out

	def testReplay(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			getLogger().setLevel(ERROR)
			iface = self.config.iface_cache.get_interface('http://example.com:8000/Hello.xml')
			mtime = int(os.stat('Hello-new.xml').st_mtime)
			with open('Hello-new.xml', 'rb') as stream:
				self.config.iface_cache.update_feed_from_network(iface.uri, stream.read(), mtime + 10000)

			trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
			run_server(server.Give404('/Hello.xml'), 'latest.xml', '/0mirror/keys/6FCF121BE2390E0B.gpg', 'Hello.xml')
			driver = Driver(requirements = Requirements('http://example.com:8000/Hello.xml'), config = self.config)
			self.config.feed_mirror = 'http://example.com:8000/0mirror'

			# Update from mirror (should ignore out-of-date timestamp)
			refreshed = self.config.fetcher.download_and_import_feed(iface.uri, self.config.iface_cache)
			tasks.wait_for_blocker(refreshed)

			# Update from upstream (should report an error)
			refreshed = self.config.fetcher.download_and_import_feed(iface.uri, self.config.iface_cache)
			try:
				tasks.wait_for_blocker(refreshed)
				raise Exception("Should have been rejected!")
			except model.SafeException as ex:
				assert "New feed's modification time is before old version" in str(ex)

			# Must finish with the newest version
			self.assertEqual(1235911552, self.config.iface_cache._get_signature_date(iface.uri))
		finally:
			sys.stdout = old_out

	def testBackground(self, verbose = False):
		r = Requirements('http://example.com:8000/Hello.xml')
		d = Driver(requirements = r, config = self.config)
		self.import_feed(r.interface_uri, 'Hello.xml')
		self.config.freshness = 0
		self.config.network_use = model.network_minimal
		d.solver.solve(r.interface_uri, arch.get_host_architecture())
		assert d.solver.ready, d.solver.get_failure_reason()

		@tasks.async
		def choose_download(registed_cb, nid, actions):
			try:
				assert actions == ['download', 'Download'], actions
				registed_cb(nid, 'download')
			except:
				import traceback
				traceback.print_exc()
			yield None

		global ran_gui
		ran_gui = False
		os.environ['DISPLAY'] = 'dummy'
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg')
			my_dbus.system_services = {"org.freedesktop.NetworkManager": {"/org/freedesktop/NetworkManager": NetworkManager()}}
			my_dbus.user_callback = choose_download

			with trapped_exit(1):
				from zeroinstall.injector import config
				key_info = config.DEFAULT_KEY_LOOKUP_SERVER
				config.DEFAULT_KEY_LOOKUP_SERVER = None
				try:
					background.spawn_background_update(d, verbose)
				finally:
					config.DEFAULT_KEY_LOOKUP_SERVER = key_info
		finally:
			sys.stdout = old_out
		assert ran_gui

	def testBackgroundVerbose(self):
		self.testBackground(verbose = True)

	def testBackgroundApp(self):
		my_dbus.system_services = {"org.freedesktop.NetworkManager": {"/org/freedesktop/NetworkManager": NetworkManager()}}

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')

		global ran_gui

		with output_suppressed():
			# Select a version of Hello
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', 'HelloWorld.tgz')
			r = Requirements('http://example.com:8000/Hello.xml')
			driver = Driver(requirements = r, config = self.config)
			tasks.wait_for_blocker(driver.solve_with_downloads())
			assert driver.solver.ready
			kill_server_process()

			# Save it as an app
			app = self.config.app_mgr.create_app('test-app', r)
			app.set_selections(driver.solver.selections)
			timestamp = os.path.join(app.path, 'last-checked')
			last_check_attempt = os.path.join(app.path, 'last-check-attempt')
			selections_path = os.path.join(app.path, 'selections.xml')

			def reset_timestamps():
				ran_gui = False
				os.utime(timestamp, (1, 1))		# 1970
				os.utime(selections_path, (1, 1))
				if os.path.exists(last_check_attempt):
					os.unlink(last_check_attempt)

			# Download the implementation
			sels = app.get_selections()
			run_server('HelloWorld.tgz')
			tasks.wait_for_blocker(app.download_selections(sels))
			kill_server_process()

			# Not time for a background update yet
			self.config.freshness = 100
			dl = app.download_selections(sels)
			assert dl == None
			assert not ran_gui

			# Trigger a background update - no updates found
			reset_timestamps()
			run_server('Hello.xml')
			with trapped_exit(1):
				dl = app.download_selections(sels)
				assert dl == None
			assert not ran_gui
			self.assertNotEqual(1, os.stat(timestamp).st_mtime)
			self.assertEqual(1, os.stat(selections_path).st_mtime)
			kill_server_process()

			# Change the selections
			sels_path = os.path.join(app.path, 'selections.xml')
			with open(sels_path) as stream:
				old = stream.read()
			with open(sels_path, 'w') as stream:
				stream.write(old.replace('Hello', 'Goodbye'))

			# Trigger another background update - metadata changes found
			reset_timestamps()
			run_server('Hello.xml')
			with trapped_exit(1):
				dl = app.download_selections(sels)
				assert dl == None
			assert not ran_gui
			self.assertNotEqual(1, os.stat(timestamp).st_mtime)
			self.assertNotEqual(1, os.stat(selections_path).st_mtime)
			kill_server_process()

			# Trigger another background update - GUI needed now

			# Delete cached implementation so we need to download it again
			stored = sels.selections['http://example.com:8000/Hello.xml'].get_path(self.config.stores)
			assert os.path.basename(stored).startswith('sha1')
			ro_rmtree(stored)

			# Replace with a valid local feed so we don't have to download immediately
			with open(sels_path, 'w') as stream:
				stream.write(local_hello)
			sels = app.get_selections()

			os.environ['DISPLAY'] = 'dummy'
			reset_timestamps()
			run_server('Hello.xml')
			with trapped_exit(1):
				dl = app.download_selections(sels)
				assert dl == None
			assert ran_gui	# (so doesn't actually update)
			kill_server_process()

			# Now again with no DISPLAY
			reset_timestamps()
			del os.environ['DISPLAY']
			run_server('Hello.xml', 'HelloWorld.tgz')
			with trapped_exit(1):
				dl = app.download_selections(sels)
				assert dl == None
			assert ran_gui	# (so doesn't actually update)

			self.assertNotEqual(1, os.stat(timestamp).st_mtime)
			self.assertNotEqual(1, os.stat(selections_path).st_mtime)
			kill_server_process()

			sels = app.get_selections()
			sel, = sels.selections.values()
			self.assertEqual("sha1=3ce644dc725f1d21cfcf02562c76f375944b266a", sel.id)

			# Untrust the key
			trust.trust_db.untrust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')

			os.environ['DISPLAY'] = 'dummy'
			reset_timestamps()
			run_server('Hello.xml')
			with trapped_exit(1):
				#import logging; logging.getLogger().setLevel(logging.INFO)
				dl = app.download_selections(sels)
				assert dl == None
			assert ran_gui
			kill_server_process()

			# Update not triggered because of last-check-attempt
			ran_gui = False
			os.utime(timestamp, (1, 1))		# 1970
			os.utime(selections_path, (1, 1))
			dl = app.download_selections(sels)
			assert dl == None
			assert not ran_gui

	def testAbort(self):
		dl = download.Download("http://localhost/test.tgz", auto_delete = True)
		path = dl.tempfile.name
		dl.abort()
		assert not os.path.exists(path)
		assert dl._aborted.happened
		assert dl.tempfile is None

		dl = download.Download("http://localhost/test.tgz", auto_delete = False)
		path = dl.tempfile.name
		dl.abort()
		assert not os.path.exists(path)
		assert dl._aborted.happened
		assert dl.tempfile is None

if __name__ == '__main__':
	try:
		unittest.main()
	finally:
		kill_server_process()
