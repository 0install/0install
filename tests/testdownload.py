#!/usr/bin/env python
from __future__ import with_statement
from basetest import BaseTest
import sys, tempfile, os
from StringIO import StringIO
import unittest, signal
from logging import getLogger, WARN, ERROR
from contextlib import contextmanager

sys.path.insert(0, '..')

os.environ["http_proxy"] = "localhost:8000"

from zeroinstall.injector import model, autopolicy, gpg, iface_cache, download, reader, trust, handler, background, arch, selections, qdom
from zeroinstall.zerostore import Store, NotStored; Store._add_with_helper = lambda *unused: False
from zeroinstall.support import basedir, tasks
from zeroinstall.injector import fetch
import data
import my_dbus

fetch.DEFAULT_KEY_LOOKUP_SERVER = 'http://localhost:3333/key-info'

import server

ran_gui = False
def raise_gui(*args):
	global ran_gui
	ran_gui = True
background._detach = lambda: False
background._exec_gui = raise_gui

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
		except BaseException, ex:
			# Don't abort unit-tests if someone raises SystemExit
			raise Exception(str(type(ex)) + " " + str(ex))
	finally:
		sys.stdout = old_stdout
		sys.stderr = old_stderr

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

class DummyHandler(handler.Handler):
	__slots__ = ['ex', 'tb']
	
	def __init__(self):
		handler.Handler.__init__(self)
		self.ex = None

	def wait_for_blocker(self, blocker):
		self.ex = None
		handler.Handler.wait_for_blocker(self, blocker)
		if self.ex:
			raise self.ex, None, self.tb
	
	def report_error(self, ex, tb = None):
		assert self.ex is None, self.ex
		self.ex = ex
		self.tb = tb

		#import traceback
		#traceback.print_exc()

class NetworkManager:
	def state(self):
		return 3	# NM_STATUS_CONNECTED

class TestDownload(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		self.child = None

		trust.trust_db.watchers = []
	
	def tearDown(self):
		BaseTest.tearDown(self)
		if self.child is not None:
			os.kill(self.child, signal.SIGTERM)
			os.waitpid(self.child, 0)
			self.child = None
	
	def testRejectKey(self):
		with output_suppressed():
			self.child = server.handle_requests('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello', download_only = False,
						       handler = DummyHandler())
			assert policy.need_download()
			sys.stdin = Reply("N\n")
			try:
				policy.download_and_execute(['Hello'])
				assert 0
			except model.SafeException, ex:
				if "has no usable implementations" not in str(ex):
					raise ex
				if "Not signed with a trusted key" not in str(policy.handler.ex):
					raise ex
	
	def testRejectKeyXML(self):
		with output_suppressed():
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			policy = autopolicy.AutoPolicy('http://example.com:8000/Hello.xml', download_only = False,
						       handler = DummyHandler())
			assert policy.need_download()
			sys.stdin = Reply("N\n")
			try:
				policy.download_and_execute(['Hello'])
				assert 0
			except model.SafeException, ex:
				if "has no usable implementations" not in str(ex):
					raise ex
				if "Not signed with a trusted key" not in str(policy.handler.ex):
					raise
	
	def testImport(self):
		from zeroinstall.injector import cli

		rootLogger = getLogger()
		rootLogger.disabled = True
		try:
			try:
				cli.main(['--import', '-v', 'NO-SUCH-FILE'])
				assert 0
			except model.SafeException, ex:
				assert 'NO-SUCH-FILE' in str(ex)
		finally:
			rootLogger.disabled = False
			rootLogger.setLevel(WARN)

		hello = iface_cache.iface_cache.get_feed('http://localhost:8000/Hello')
		self.assertEquals(None, hello)

		with output_suppressed():
			self.child = server.handle_requests('6FCF121BE2390E0B.gpg')
			sys.stdin = Reply("Y\n")

			assert not trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')
			cli.main(['--import', 'Hello'])
			assert trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')

			# Check we imported the interface after trusting the key
			hello = iface_cache.iface_cache.get_feed('http://localhost:8000/Hello', force = True)
			self.assertEquals(1, len(hello.implementations))

			# Shouldn't need to prompt the second time
			sys.stdin = None
			cli.main(['--import', 'Hello'])

	def testSelections(self):
		from zeroinstall.injector import cli
		root = qdom.parse(file("selections.xml"))
		sels = selections.Selections(root)
		class Options: dry_run = False

		with output_suppressed():
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")
			try:
				iface_cache.iface_cache.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
				assert False
			except NotStored:
				pass
			cli.main(['--download-only', 'selections.xml'])
			path = iface_cache.iface_cache.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

			assert sels.download_missing(iface_cache.iface_cache, None) is None

	def testHelpers(self):
		from zeroinstall import helpers

		with output_suppressed():
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")
			sels = helpers.ensure_cached('http://example.com:8000/Hello.xml')
			path = iface_cache.iface_cache.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))
			assert sels.download_missing(iface_cache.iface_cache, None) is None

	def testSelectionsWithFeed(self):
		from zeroinstall.injector import cli
		root = qdom.parse(file("selections.xml"))
		sels = selections.Selections(root)

		with output_suppressed():
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")

			from zeroinstall.injector.handler import Handler
			handler = Handler()
			fetcher = fetch.Fetcher(handler)
			handler.wait_for_blocker(fetcher.download_and_import_feed('http://example.com:8000/Hello.xml', iface_cache.iface_cache))

			cli.main(['--download-only', 'selections.xml'])
			path = iface_cache.iface_cache.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

			assert sels.download_missing(iface_cache.iface_cache, None) is None
	
	def testAcceptKey(self):
		with output_suppressed():
			self.child = server.handle_requests('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello', download_only = False,
							handler = DummyHandler())
			assert policy.need_download()
			sys.stdin = Reply("Y\n")
			try:
				policy.download_and_execute(['Hello'], main = 'Missing')
				assert 0
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
	
	def testDistro(self):
		with output_suppressed():
			native_url = 'http://example.com:8000/Native.xml'

			# Initially, we don't have the feed at all...
			master_feed = iface_cache.iface_cache.get_feed(native_url)
			assert master_feed is None, master_feed

			trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
			self.child = server.handle_requests('Native.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
			h = DummyHandler()
			policy = autopolicy.AutoPolicy(native_url, download_only = False, handler = h)
			assert policy.need_download()

			solve = policy.solve_with_downloads()
			h.wait_for_blocker(solve)
			tasks.check(solve)

			master_feed = iface_cache.iface_cache.get_feed(native_url)
			assert master_feed is not None
			assert master_feed.implementations == {}

			distro_feed_url = master_feed.get_distro_feed()
			assert distro_feed_url is not None
			distro_feed = iface_cache.iface_cache.get_feed(distro_feed_url)
			assert distro_feed is not None
			assert len(distro_feed.implementations) == 2, distro_feed.implementations

	def testWrongSize(self):
		with output_suppressed():
			self.child = server.handle_requests('Hello-wrong-size', '6FCF121BE2390E0B.gpg',
							'/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello-wrong-size', download_only = False,
							handler = DummyHandler())
			assert policy.need_download()
			sys.stdin = Reply("Y\n")
			try:
				policy.download_and_execute(['Hello'], main = 'Missing')
				assert 0
			except model.SafeException, ex:
				if "Downloaded archive has incorrect size" not in str(ex):
					raise ex

	def testRecipe(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests(('HelloWorld.tar.bz2', 'dummy_1-1_all.deb'))
			policy = autopolicy.AutoPolicy(os.path.abspath('Recipe.xml'), download_only = False)
			try:
				policy.download_and_execute([])
				assert False
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out

	def testSymlink(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests(('HelloWorld.tar.bz2', 'HelloSym.tgz'))
			policy = autopolicy.AutoPolicy(os.path.abspath('RecipeSymlink.xml'), download_only = False,
							handler = DummyHandler())
			try:
				policy.download_and_execute([])
				assert False
			except model.SafeException, ex:
				if 'Attempt to unpack dir over symlink "HelloWorld"' not in str(ex):
					raise
			self.assertEquals(None, basedir.load_first_cache('0install.net', 'implementations', 'main'))
		finally:
			sys.stdout = old_out

	def testAutopackage(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('HelloWorld.autopackage')
			policy = autopolicy.AutoPolicy(os.path.abspath('Autopackage.xml'), download_only = False)
			try:
				policy.download_and_execute([])
				assert False
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise
		finally:
			sys.stdout = old_out

	def testRecipeFailure(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('*')
			policy = autopolicy.AutoPolicy(os.path.abspath('Recipe.xml'), download_only = False,
							handler = DummyHandler())
			try:
				policy.download_and_execute([])
				assert False
			except download.DownloadError, ex:
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
			self.child = server.handle_requests(server.Give404('/Hello.xml'), 'latest.xml', '/0mirror/keys/6FCF121BE2390E0B.gpg')
			policy = autopolicy.AutoPolicy('http://example.com:8000/Hello.xml', download_only = False)
			policy.fetcher.feed_mirror = 'http://example.com:8000/0mirror'

			refreshed = policy.solve_with_downloads()
			policy.handler.wait_for_blocker(refreshed)
			assert policy.ready
		finally:
			sys.stdout = old_out

	def testReplay(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			getLogger().setLevel(ERROR)
			iface = iface_cache.iface_cache.get_interface('http://example.com:8000/Hello.xml')
			mtime = int(os.stat('Hello-new.xml').st_mtime)
			iface_cache.iface_cache.update_feed_from_network(iface.uri, file('Hello-new.xml').read(), mtime + 10000)

			trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
			self.child = server.handle_requests(server.Give404('/Hello.xml'), 'latest.xml', '/0mirror/keys/6FCF121BE2390E0B.gpg', 'Hello.xml')
			policy = autopolicy.AutoPolicy('http://example.com:8000/Hello.xml', download_only = False)
			policy.fetcher.feed_mirror = 'http://example.com:8000/0mirror'

			# Update from mirror (should ignore out-of-date timestamp)
			refreshed = policy.fetcher.download_and_import_feed(iface.uri, iface_cache.iface_cache)
			policy.handler.wait_for_blocker(refreshed)

			# Update from upstream (should report an error)
			refreshed = policy.fetcher.download_and_import_feed(iface.uri, iface_cache.iface_cache)
			try:
				policy.handler.wait_for_blocker(refreshed)
				raise Exception("Should have been rejected!")
			except model.SafeException, ex:
				assert "New feed's modification time is before old version" in str(ex)

			# Must finish with the newest version
			self.assertEquals(1235911552, iface_cache.iface_cache._get_signature_date(iface.uri))
		finally:
			sys.stdout = old_out

	def testBackground(self, verbose = False):
		p = autopolicy.AutoPolicy('http://example.com:8000/Hello.xml')
		reader.update(iface_cache.iface_cache.get_interface(p.root), 'Hello.xml')
		p.freshness = 0
		p.network_use = model.network_minimal
		p.solver.solve(p.root, arch.get_host_architecture())
		assert p.ready

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
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg')
			my_dbus.system_services = {"org.freedesktop.NetworkManager": {"/org/freedesktop/NetworkManager": NetworkManager()}}
			my_dbus.user_callback = choose_download
			pid = os.getpid()
			old_exit = os._exit
			def my_exit(code):
				# The background handler runs in the same process
				# as the tests, so don't let it abort.
				if os.getpid() == pid:
					raise SystemExit(code)
				# But, child download processes are OK
				old_exit(code)
			key_info = fetch.DEFAULT_KEY_LOOKUP_SERVER
			fetch.DEFAULT_KEY_LOOKUP_SERVER = None
			try:
				try:
					os._exit = my_exit
					background.spawn_background_update(p, verbose)
					assert False
				except SystemExit, ex:
					self.assertEquals(1, ex.code)
			finally:
				os._exit = old_exit
				fetch.DEFAULT_KEY_LOOKUP_SERVER = key_info
		finally:
			sys.stdout = old_out
		assert ran_gui

	def testBackgroundVerbose(self):
		self.testBackground(verbose = True)

if __name__ == '__main__':
	unittest.main()
