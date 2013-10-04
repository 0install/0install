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
from zeroinstall.injector import model, gpg, download, trust, selections, qdom, config, namespaces, distro
from zeroinstall.injector.scheduler import Site
from zeroinstall.zerostore import NotStored
from zeroinstall.support import basedir, tasks, ro_rmtree
from zeroinstall.injector import fetch
import data
import my_dbus

import server

mydir = os.path.dirname(os.path.abspath(__file__))

ran_gui = False
def raise_gui(*args, **kwargs):
	global ran_gui
	use_gui = kwargs.get('use_gui', True)
	assert use_gui != False
	if 'DISPLAY' in os.environ:
		ran_gui = True
	else:
		assert use_gui is None
		return helpers.DontUseGUI

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

# Count how many downloads we request so we can check it
traced_downloads = None
orig_download = Site.download
def wrap_download(self, step, timeout = None):
	traced_downloads.append(step.url)
	return orig_download(self, step)
Site.download = wrap_download

def get_unavailable_selections(sels, config, include_packages):
	"""Find those selections which are not present.
	Local implementations are available if their directory exists.
	Other 0install implementations are available if they are in the cache.
	Package implementations are available if the Distribution says so.
	@param include_packages: whether to include <package-implementation>s
	@type include_packages: bool
	@rtype: [Selection]
	@since: 1.16"""
	iface_cache = config.iface_cache
	stores = config.stores

	# Check that every required selection is cached
	def needs_download(sel):
		if sel.id.startswith('package:'):
			if not include_packages: return False
			if sel.quick_test_file:
				if not os.path.exists(sel.quick_test_file):
					return True
				required_mtime = sel.quick_test_mtime
				if required_mtime is None:
					return False
				else:
					return int(os.stat(sel.quick_test_file).st_mtime) != required_mtime

			feed = iface_cache.get_feed(sel.feed)
			if not feed: return False
			impl = feed.implementations.get(sel.id, None)
			return impl is None or not impl.installed
		elif sel.local_path:
			return False
		else:
			return sel.get_path(stores, missing_ok = True) is None

	return [sel for sel in sels.selections.values() if needs_download(sel)]

class TestDownload(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		self.config.handler.allow_downloads = True
		self.config.key_info_server = 'http://localhost:3333/key-info'
		self.config.fetcher = fetch.Fetcher(self.config)

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

		global traced_downloads
		traced_downloads = []

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
	
	def testImport(self):
		out, err = self.run_ocaml(['import', '-v', 'NO-SUCH-FILE'])
		assert 'NO-SUCH-FILE' in err
		assert not out, out

		hello = self.config.iface_cache.get_feed('http://localhost:8000/Hello')
		self.assertEqual(None, hello)

		run_server('6FCF121BE2390E0B.gpg')

		assert not trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')
		out, err = self.run_ocaml(['import', 'Hello'], stdin = 'Y\n')
		assert not out, out
		assert "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000" in err, err
		assert trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')

		# Check we imported the interface after trusting the key
		hello = self.config.iface_cache.get_feed('http://localhost:8000/Hello', force = True)
		self.assertEqual(1, len(hello.implementations))

		self.assertEqual(None, hello.local_path)

		# Shouldn't need to prompt the second time
		sys.stdin = None
		out, err = self.run_ocaml(['import', 'Hello'])
		assert not out, out
		assert not err, err

	def testSelections(self):
		with open("selections.xml", 'rb') as stream:
			root = qdom.parse(stream)
		sels = selections.Selections(root)

		run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		try:
			self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert False
		except NotStored:
			pass
		out, err = self.run_ocaml(['download', 'selections.xml'], stdin = "Y\n")
		assert not out, out
		assert "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for example.com:8000" in err, err
		path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

		assert get_unavailable_selections(sels, self.config, include_packages = True) == []

	def testSelectionsWithFeed(self):
		with open("selections.xml", 'rb') as stream:
			root = qdom.parse(stream)
		sels = selections.Selections(root)

		with output_suppressed():
			run_server('Hello.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')

			out, err = self.run_ocaml(['download', 'selections.xml'], stdin = 'Y\n')
			assert not out, out
			assert 'Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for example.com:8000' in err, err
			path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
			assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

			assert get_unavailable_selections(sels, self.config, include_packages = True) == []
	
	def testAcceptKey(self):
		run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['run', '--main=Missing', '-v', 'http://localhost:8000/Hello'], stdin = 'Y\n')
		assert not out, out
		assert 'Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000' in err, err
		assert "HelloWorld/Missing' does not exist" in err, err
	
	def testDryRun(self):
		run_server('Hello', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['run', '--dry-run', 'http://localhost:8000/Hello', 'Hello'], stdin = 'Y\n')
		# note: the Python redirects dry-run messages to stderr, as it's using stdout for IPC
		assert '[dry-run] would trust key DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000' in err, err
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

	def testDistro(self):
		native_url = 'http://example.com:8000/Native.xml'

		# Initially, we don't have the feed at all...
		master_feed = self.config.iface_cache.get_feed(native_url)
		assert master_feed is None, master_feed

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
		run_server('Native.xml', '6FCF121BE2390E0B.gpg', '/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B')
		out, err = self.run_ocaml(['download', native_url])
		assert not out, out
		assert "Can't find all required implementations" in err, err

		master_feed = self.config.iface_cache.get_feed(native_url, force = True)
		assert master_feed is not None
		assert master_feed.implementations == {}

		blocker = distro._host_distribution.fetch_candidates(master_feed.get_package_impls(distro._host_distribution))
		if blocker:
			tasks.wait_for_blocker(blocker)
		distro_feed_url = master_feed.get_distro_feed()
		assert distro_feed_url is not None
		distro_feed = distro._host_distribution.get_feed(master_feed.url, master_feed.get_package_impls(distro._host_distribution))
		assert distro_feed is not None
		assert len(distro_feed.implementations) == 2, distro_feed.implementations

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

	def testMirrors(self):
		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.mirror = 'http://example.com:8000/0mirror'
		child_config.save_globals()

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
		run_server(server.Give404('/Hello.xml'),
				'/0mirror/feeds/http/example.com:8000/Hello.xml/latest.xml',
				'/0mirror/keys/6FCF121BE2390E0B.gpg',
				server.Give404('/HelloWorld.tgz'),
				'/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz')
		out, err = self.run_ocaml(['download', 'http://example.com:8000/Hello.xml', '--xml'], binary = True)
		assert b"Primary download failed; trying mirror URL 'http://roscidus.com/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz'" in err, err.decode('utf-8')
		sels = selections.Selections(qdom.parse(BytesIO(out)))

		path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

	def testImplMirror(self):
		# This is like testMirror, except we have a different archive (that generates the same content),
		# rather than an exact copy of the unavailable archive.

		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.mirror = 'http://example.com:8000/0mirror'
		child_config.save_globals()

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
		run_server('/Hello.xml',
				'/6FCF121BE2390E0B.gpg',
				server.Give404('/HelloWorld.tgz'),
				server.Give404('/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz'),
				'/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
		out, err = self.run_ocaml(['download', '-v', 'http://example.com:8000/Hello.xml', '--xml'], binary = True)

		assert b'Missing: HelloWorld.tgz: trying implementation mirror at http://roscidus.com/0mirror' in err, err #/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a' in err, err.decode('utf-8')
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		path = self.config.stores.lookup_any(sels.selections['http://example.com:8000/Hello.xml'].digests)
		assert os.path.exists(os.path.join(path, 'HelloWorld', 'main'))

	def testImplMirrorFails(self):
		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = 'http://localhost:3333/key-info'
		child_config.mirror = 'http://example.com:8000/0mirror'
		child_config.save_globals()

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
		run_server('/Hello.xml',
				'/6FCF121BE2390E0B.gpg',
				server.Give404('/HelloWorld.tgz'),
				server.Give404('/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz'),
				server.Give404('/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a'))
		out, err = self.run_ocaml(['download', '-vv', 'http://example.com:8000/Hello.xml'])
		assert not out, out
		assert "Exit status: 1" in err, err
		assert 'Missing: HelloWorld.tgz' in err, err

		for x in [
			'http://example.com:8000/Hello.xml',
			'http://example.com:8000/6FCF121BE2390E0B.gpg',
			# The original archive:
			'http://example.com:8000/HelloWorld.tgz',
			# Mirror of original archive:
			'http://roscidus.com/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz',
			# Mirror of implementation:
			'http://roscidus.com/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a'
			]:
			assert x in err, (x, err)

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

	def testReplay(self):
		with resourcewarnings_suppressed():
			old_out = sys.stdout
			try:
				sys.stdout = StringIO()
				getLogger().setLevel(ERROR)

				iface = self.config.iface_cache.get_interface('http://example.com:8000/Hello.xml')
				upstream_dir = basedir.save_cache_path(namespaces.config_site, 'interfaces')
				cached = os.path.join(upstream_dir, model.escape(iface.uri))

				shutil.copyfile('Hello-new.xml', cached)

				trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')
				run_server(server.Give404('/Hello.xml'), 'latest.xml', '/0mirror/keys/6FCF121BE2390E0B.gpg', 'Hello.xml')

				child_config = config.Config()
				child_config.auto_approve_keys = False
				child_config.mirror = 'http://example.com:8000/0mirror'
				child_config.save_globals()

				# Update from mirror (should ignore out-of-date timestamp)
				out, err = self.run_ocaml(['select', '--refresh', '-v', iface.uri])
				assert 'Version: 1' in out, out
				assert 'Version from mirror is older than cached version; ignoring it' in err, err

				# Update from upstream (should report an error)
				out, err = self.run_ocaml(['select', '--refresh', '-v', iface.uri])
				assert 'Version: 1' in out, out
				assert "New feed's modification time is before old version" in err, err

				# Must finish with the newest version
				with open(cached, 'rb') as stream:
					actual = stream.read()
				with open('Hello-new.xml', 'rb') as stream:
					expected = stream.read()
				self.assertEqual(expected, actual)
			finally:
				sys.stdout = old_out

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

	def testBackgroundApp(self):
		my_dbus.system_services = {"org.freedesktop.NetworkManager": {"/org/freedesktop/NetworkManager": NetworkManager()}}

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')

		global ran_gui

		# Create an app, downloading a version of Hello
		run_server('Hello.xml', '6FCF121BE2390E0B.gpg', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['add', 'test-app', 'http://example.com:8000/Hello.xml'])
		assert not out, out
		assert not err, err
		kill_server_process()
		app = basedir.load_first_config(namespaces.config_site, "apps", 'test-app')
		timestamp = os.path.join(app, 'last-checked')
		last_check_attempt = os.path.join(app, 'last-check-attempt')
		selections_path = os.path.join(app, 'selections.xml')

		def reset_timestamps():
			global ran_gui
			ran_gui = False
			os.utime(timestamp, (1, 1))		# 1970
			os.utime(selections_path, (1, 1))
			if os.path.exists(last_check_attempt):
				os.unlink(last_check_attempt)

		# Not time for a background update yet
		self.config.freshness = 100
		self.run_ocaml(['download', 'test-app'])
		assert not ran_gui

		# Trigger a background update - no updates found
		os.environ['ZEROINSTALL_TEST_BACKGROUND'] = 'true'
		reset_timestamps()
		run_server('Hello.xml')
		# (-vv mode makes us wait for the background process to finish)
		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'Background update: no updates found for test-app' in err, err
		self.assertNotEqual(1, os.stat(timestamp).st_mtime)
		self.assertEqual(1, os.stat(selections_path).st_mtime)
		kill_server_process()

		# Change the selections
		sels_path = os.path.join(app, 'selections.xml')
		with open(sels_path) as stream:
			old = stream.read()
		with open(sels_path, 'w') as stream:
			stream.write(old.replace('Hello', 'Goodbye'))

		# Trigger another background update - metadata changes found
		reset_timestamps()
		run_server('Hello.xml')

		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'Quick solve succeeded; saving new selections' in err, err

		self.assertNotEqual(1, os.stat(timestamp).st_mtime)
		self.assertNotEqual(1, os.stat(selections_path).st_mtime)
		kill_server_process()

		# Trigger another background update - GUI needed now

		# Delete cached implementation so we need to download it again
		out, err = self.run_ocaml(['select', '--xml', 'test-app'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		stored = sels.selections['http://example.com:8000/Hello.xml'].get_path(self.config.stores)
		assert os.path.basename(stored).startswith('sha1')
		ro_rmtree(stored)

		# Replace with a valid local feed so we don't have to download immediately
		with open(sels_path, 'w') as stream:
			stream.write(local_hello)

		os.environ['DISPLAY'] = 'dummy'
		reset_timestamps()
		run_server('Hello.xml')
		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'GUI unavailable; downloading with no UI' in err, err
		kill_server_process()

		# Now again with no DISPLAY
		reset_timestamps()
		del os.environ['DISPLAY']
		run_server('Hello.xml', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'GUI unavailable; downloading with no UI' in err, err

		self.assertNotEqual(1, os.stat(timestamp).st_mtime)
		self.assertNotEqual(1, os.stat(selections_path).st_mtime)
		kill_server_process()

		out, err = self.run_ocaml(['select', '--xml', 'test-app'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		sel, = sels.selections.values()
		self.assertEqual("sha1=3ce644dc725f1d21cfcf02562c76f375944b266a", sel.id)

		# Untrust the key
		trust.trust_db.untrust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')

		os.environ['DISPLAY'] = 'dummy'
		reset_timestamps()
		run_server('Hello.xml')
		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'need to switch to GUI to confirm keys' in err, err
		assert "Can't update 0install app 'test-app' without user intervention (run '0install update test-app' to fix)" in err, err
		kill_server_process()

		# Update not triggered because of last-check-attempt
		ran_gui = False
		os.utime(timestamp, (1, 1))		# 1970
		os.utime(selections_path, (1, 1))
		out, err = self.run_ocaml(['download', '-vv', 'test-app'])
		assert not out, out
		assert 'Tried to check within last hour; not trying again now' in err, err

	def testBackgroundUnsolvable(self):
		my_dbus.system_services = {"org.freedesktop.NetworkManager": {"/org/freedesktop/NetworkManager": NetworkManager()}}

		trust.trust_db.trust_key('DE937DD411906ACF7C263B396FCF121BE2390E0B', 'example.com:8000')

		# Create new app
		run_server('Hello.xml', '6FCF121BE2390E0B.gpg', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['add', 'test-app', 'http://example.com:8000/Hello.xml'])
		kill_server_process()
		assert not out, out
		assert not err, err

		# Delete cached implementation so we need to download it again
		out, err = self.run_ocaml(['select', '--xml', 'test-app'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		stored = sels.selections['http://example.com:8000/Hello.xml'].get_path(self.config.stores)
		assert os.path.basename(stored).startswith('sha1')
		ro_rmtree(stored)

		out, err = self.run_ocaml(['select', '--xml', 'test-app'], binary = True)
		assert not err, err
		sels = qdom.parse(BytesIO(out))
		# Replace the selection with a bogus and unusable <package-implementation>
		sel, = sels.childNodes
		sel.attrs['id'] = "package:dummy:badpackage"
		sel.attrs['from-feed'] = "distribution:http://example.com:8000/Hello.xml"
		sel.attrs['package'] = "badpackage"
		sel.attrs['main'] = '/i/dont/exist'

		app = basedir.load_first_config(namespaces.config_site, "apps", 'test-app')

		with open(os.path.join(app, 'selections.xml'), 'wb') as stream:
			stream.write(qdom.to_UTF8(sels))

		# Not time for a background update yet, but the missing binary should trigger
		# an update anyway.
		self.config.freshness = 0

		# Check we try to launch the GUI...
		os.environ['DISPLAY'] = 'dummy'
		run_server('Hello.xml', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['download', '--xml', '-v', 'test-app'], binary = True)
		kill_server_process()
		err = err.decode('utf-8')
		assert 'get new selections; current ones are not usable' in err, err
		assert 'check-gui' in err, err
		sels = selections.Selections(qdom.parse(BytesIO(out)))

		# Check we can also work without the GUI...
		del os.environ['DISPLAY']

		# Delete cached implementation so we need to download it again
		out, err = self.run_ocaml(['select', '--xml', 'test-app'], binary = True)
		sels = selections.Selections(qdom.parse(BytesIO(out)))
		stored = sels.selections['http://example.com:8000/Hello.xml'].get_path(self.config.stores)
		assert os.path.basename(stored).startswith('sha1')
		ro_rmtree(stored)

		run_server('Hello.xml', 'HelloWorld.tgz')
		out, err = self.run_ocaml(['download', '--xml', '-v', 'test-app'], binary = True)
		kill_server_process()
		err = err.decode('utf-8')
		assert 'get new selections; current ones are not usable' in err, err
		assert 'check-gui' not in err, err
		sels = selections.Selections(qdom.parse(BytesIO(out)))

		# Now trigger a background update which discovers that no solution is possible
		timestamp = os.path.join(app, 'last-checked')
		last_check_attempt = os.path.join(app, 'last-check-attempt')
		selections_path = os.path.join(app, 'selections.xml')
		def reset_timestamps():
			global ran_gui
			ran_gui = False
			os.utime(timestamp, (1, 1))		# 1970
			os.utime(selections_path, (1, 1))
			if os.path.exists(last_check_attempt):
				os.unlink(last_check_attempt)
		reset_timestamps()

		out, err = self.run_ocaml(['destroy', 'test-app'])
		assert not out, out
		assert not err, err

		run_server('Hello.xml')
		out, err = self.run_ocaml(['add', '--source', 'test-app', 'http://example.com:8000/Hello.xml'])
		assert not out, out
		assert 'We want source and this is a binary' in err, err
	
	def testChunked(self):
		if sys.version_info[0] < 3:
			return	# not a problem with Python 2
		run_server('chunked')
		dl = self.config.fetcher.download_url('http://localhost/chunked')
		tmp = dl.tempfile
		tasks.wait_for_blocker(dl.downloaded)
		tasks.check(dl.downloaded)
		tmp.seek(0)
		self.assertEqual(b'hello world', tmp.read())
		kill_server_process()

	def testAbort(self):
		dl = download.Download("http://localhost/test.tgz", auto_delete = True)
		dl.abort()
		assert dl._aborted.happened
		assert dl.tempfile is None

		dl = download.Download("http://localhost/test.tgz", auto_delete = False)
		path = dl.tempfile.name
		dl.abort()
		assert not os.path.exists(path)
		assert dl._aborted.happened
		assert dl.tempfile is None

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
		out, err = self.run_0install(['search'])
		assert out.lower().startswith("usage:")
		assert 'QUERY' in out, out

		run_server('/0mirror/search/')
		self.config.mirror = 'http://example.com:8000/0mirror'
		out, err = self.run_0install(['search', 'firefox'])
		kill_server_process()
		self.assertEqual("", err)
		assert 'Firefox - Webbrowser' in out, out

if __name__ == '__main__':
	try:
		unittest.main()
	finally:
		kill_server_process()
