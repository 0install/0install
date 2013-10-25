#!/usr/bin/env python
from __future__ import with_statement
from basetest import BaseTest, StringIO, BytesIO
import sys, tempfile, os, shutil
import unittest
import warnings
from logging import getLogger, ERROR
from contextlib import contextmanager

sys.path.insert(0, '..')

os.environ["http_proxy"] = "localhost:8000"

from zeroinstall import helpers
from zeroinstall.injector import model, gpg, download, trust, qdom, config, namespaces, distro
from zeroinstall.zerostore import NotStored
from zeroinstall.support import basedir, tasks, ro_rmtree
import data
import my_dbus
import selections

import server

mydir = os.path.dirname(os.path.abspath(__file__))

ran_gui = False

local_hello = """<?xml version="1.0" ?>
<selections command="run" interface="http://example.com:8000/Hello.xml" xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <selection id="." local-path='.' interface="http://example.com:8000/Hello.xml" version="0.1"><command name="run" path="foo"/></selection>
</selections>"""

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

@contextmanager
def resourcewarnings_suppressed():
	import gc
	if sys.version_info[0] < 3:
		yield
	else:
		with warnings.catch_warnings():
			warnings.filterwarnings("ignore", category = ResourceWarning)
			yield
			gc.collect()

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

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

class TestDownload(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.config.handler.allow_downloads = True
		self.config.key_info_server = 'http://localhost:3333/key-info'

		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.save_globals()

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		stream.close()

		global ran_gui
		ran_gui = False

	def tearDown(self):
		# Wait for all downloads to finish, otherwise they may interfere with other tests
		for dl in list(self.config.handler.monitored_downloads):
			try:
				tasks.wait_for_blocker(dl.downloaded)
			except:
				pass

		BaseTest.tearDown(self)
		kill_server_process()

		# Flush out ResourceWarnings
		import gc; gc.collect()

	def testRejectKey(self):
		run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')

		out, err = self.run_ocaml(['run', '-v', 'http://localhost:8000/Hello', 'Hello'], stdin = 'N\n')
		assert not out, out
		assert "Quick solve failed; can't select without updating feeds" in err, err
		assert "Valid signature from DE937DD411906ACF7C263B396FCF121BE2390E0B" in err, err
		assert "Approved for testing" in err, err

		assert "No known implementations at all" in err, err

		assert "Not signed with a trusted key" in err, err
		assert "Exit status: 1" in err, err

	def testRejectKeyXML(self):
		run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
		out, err = self.run_ocaml(['run', '-v', 'http://example.com:8000/Hello.xml'], stdin = 'N\n')
		assert not out, out
		assert "Quick solve failed; can't select without updating feeds" in err, err
		assert "Valid signature from DE937DD411906ACF7C263B396FCF121BE2390E0B" in err, err
		assert "Approved for testing" in err, err

		assert "No known implementations at all" in err, err

		assert "Not signed with a trusted key" in err, err
		assert "Exit status: 1" in err, err
	
	def testDryRun(self):
		run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['run', '--dry-run', 'http://localhost:8000/Hello', 'Hello'], stdin = 'Y\n')
		# note: the Python redirects dry-run messages to stderr, as it's using stdout for IPC
		assert '[dry-run] would trust key DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000' in out, out
		assert '[dry-run] would cache feed http://localhost:8000/Hello as ' in out, out
		assert '[dry-run] would store implementation as ' in err, err
		assert '[dry-run] would execute:' in out, out
	
	def testAutoAcceptKey(self):
		child_config = config.Config()
		child_config.auto_approve_keys = True
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.save_globals()

		run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['run', '--main=Missing', 'http://localhost:8000/Hello', 'Hello'], stdin = '')
		assert "Exit status: 1" in err, err
		assert "HelloWorld/Missing" in err, err

	def testWrongSize(self):
		run_server('Hello-wrong-size', '6FCF121BE2390E0B.gpg',
						'/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['run', '--main=Missing', 'http://localhost:8000/Hello-wrong-size', 'Hello'], stdin = 'Y\n')
		assert not out, out
		assert "Exit status: 1" in err, err
		assert "Downloaded archive has incorrect size" in err, err

	def testRecipe(self):
		run_server(('HelloWorld.tar.bz2', 'redirect/dummy_1-1_all.deb', 'dummy_1-1_all.deb'))
		out, err = self.run_ocaml(['run', os.path.abspath('Recipe.xml')])
		assert "Exit status: 1" in err, err
		assert "HelloWorld/Missing' does not exist" in err, err
	
	def testRecipeRename(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('RecipeRename.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'HelloUniverse', 'minor'))
		assert not os.path.exists(os.path.join(path, 'HelloWorld'))
		assert not os.path.exists(os.path.join(path, 'HelloUniverse', 'main'))

	def testRecipeRenameToNewDest(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('RecipeRenameToNewDest.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'bin', 'main'))
		assert not os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

	def testRecipeRemoveFile(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('RecipeRemove.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err.decode('utf-8')
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld'))
		assert not os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

	def testRecipeRemoveDir(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('RecipeRemoveDir.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err.decode('utf-8')
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert not os.path.exists(os.path.join(path, 'HelloWorld'))

	def testRecipeExtractToNewSubdirectory(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('RecipeExtractToNewDest.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'src', 'HelloWorld', 'main'))

	def testRecipeExtractToExistingSubdirectory(self):
		run_server(('HelloWorld.tar.bz2','HelloWorld.tar.bz2'))
		uri = os.path.abspath('RecipeExtractToExistingDest.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'main')) # first archive's main
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'HelloWorld', 'main')) # second archive, extracted to HelloWorld/

	def testRecipeSingleFile(self):
		run_server(('HelloWorldMain',))
		uri = os.path.abspath('RecipeSingleFile.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err.decode('utf-8')
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		with open(os.path.join(path, 'bin','main'), 'rt') as stream:
			assert 'Hello World' in stream.read()

	def testExtractToNewSubdirectory(self):
		run_server(('HelloWorld.tar.bz2',))
		uri = os.path.abspath('HelloExtractToNewDest.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		assert os.path.exists(os.path.join(path, 'src', 'HelloWorld', 'main'))

	def testDownloadFile(self):
		run_server(('HelloWorldMain',))
		uri = os.path.abspath('HelloSingleFile.xml')
		out, err = self.run_ocaml(['download', uri, '--command=', '--xml'], binary = True)
		assert not err, err
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		digests = sels.selections[uri].digests
		path = self.config.stores.lookup_any(digests)
		with open(os.path.join(path, 'main'), 'rt') as stream:
			assert 'Hello World' in stream.read()

	def testSymlink(self):
		run_server(('HelloWorld.tar.bz2', 'HelloSym.tgz'))
		out, err = self.run_ocaml(['download', os.path.abspath('RecipeSymlink.xml')])
		assert "Exit status: 1" in err, err
		assert 'Attempt to unpack dir over symlink "HelloWorld"' in err, err
		self.assertEqual(None, basedir.load_first_cache('0install.net', 'implementations', 'main'))

	def testAutopackage(self):
		run_server('HelloWorld.autopackage')
		out, err = self.run_ocaml(['run', os.path.abspath('Autopackage.xml')])
		assert "Exit status: 1" in err, err
		assert "HelloWorld/Missing" in err, err

	def testRecipeFailure(self):
		run_server('*')
		out, err = self.run_ocaml(['run', os.path.abspath('Recipe.xml')])
		assert "Exit status: 1" in err, err
		assert "Connection" in err, err

	def testLocalFeedMirror(self):
		# This is like testImplMirror, except we have a local feed.

		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.mirror = 'http://example.com:8000/0mirror'
		child_config.save_globals()

		run_server(server.Give404('/HelloWorld.tgz'),
				'/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz')
		iface_uri = model.canonical_iface_uri('Hello.xml')
		out, err = self.run_ocaml(['download', iface_uri, '--xml'], binary = True)
		assert b'Missing: HelloWorld.tgz: trying archive mirror at http://roscidus.com/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz', err

		sels = selections.Selections(qdom.parse(BytesIO(out)))
		path = self.config.stores.lookup_any(sels.selections[iface_uri].digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

	# We don't support notification actions any longer.
	def disabled_testBackground(self, verbose = False):
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
	
	def disabled_testDownloadIconFails(self):
		path = model.canonical_iface_uri(os.path.join(mydir, 'Binary.xml'))
		iface = self.config.iface_cache.get_interface(path)
		blocker = self.config.fetcher.download_icon(iface)
		try:
			tasks.wait_for_blocker(blocker)
			assert False
		except download.DownloadError as ex:
			assert "Error downloading http://localhost/missing.png" in str(ex), ex
	
	def testSearch(self):
		out, err = self.run_ocaml(['search'])
		assert out.lower().startswith("usage:")
		assert 'QUERY' in out, out

		run_server('/0mirror/search/')
		self.config.mirror = 'http://example.com:8000/0mirror'
		out, err = self.run_ocaml(['search', 'firefox'])
		kill_server_process()
		self.assertEqual("", err)
		assert 'Firefox - Webbrowser' in out, out

if __name__ == '__main__':
	try:
		unittest.main()
	finally:
		kill_server_process()
