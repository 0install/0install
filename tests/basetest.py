#!/usr/bin/env python
import locale
locale.setlocale(locale.LC_ALL, 'C')
import sys, tempfile, os, shutil, imp, time
import unittest
import logging
import warnings
from xml.dom import minidom
if sys.version_info[0] > 2:
	from io import StringIO, BytesIO
else:
	from StringIO import StringIO
	BytesIO = StringIO
warnings.filterwarnings("ignore", message = 'The CObject type')

# Catch silly mistakes...
os.environ['HOME'] = '/home/idontexist'
os.environ['LANGUAGE'] = 'C'
os.environ['LANG'] = 'C'

sys.path.insert(0, '..')
from zeroinstall.injector import qdom, background
from zeroinstall.injector import iface_cache, download, distro, model, handler, reader, trust
from zeroinstall.zerostore import NotStored, Store, Stores; Store._add_with_helper = lambda *unused, **kwargs: False
from zeroinstall import support, apps, cmd
from zeroinstall.support import basedir, tasks

class BackgroundException(Exception):
	pass

def throw_background():
	raise BackgroundException("Tried to spawn background process")

dpkgdir = os.path.join(os.path.dirname(__file__), 'dpkg')

empty_feed = qdom.parse(BytesIO(b"""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Empty</name>
<summary>just for testing</summary>
</interface>"""))

import my_dbus
sys.modules['dbus'] = my_dbus
sys.modules['dbus.glib'] = my_dbus
my_dbus.types = my_dbus
sys.modules['dbus.types'] = my_dbus
sys.modules['dbus.mainloop'] = my_dbus
sys.modules['dbus.mainloop.glib'] = my_dbus

mydir = os.path.dirname(__file__)

class ExecMan(Exception):
	def __init__(self, args):
		self.man_args = args
		Exception.__init__(self, 'ExecMan')

# Catch us trying to run the GUI and return a dummy string instead
old_execvp = os.execvp
def test_execvp(prog, args):
	if prog == sys.executable and args[1].endswith('/0launch-gui'):
		prog = os.path.join(mydir, 'test-gui')
	if prog == 'man':
		raise ExecMan(args)
	return old_execvp(prog, args)

os.execvp = test_execvp

test_locale = (None, None)
assert model.locale
class TestLocale:
	LC_ALL = 'LC_ALL'	# Note: LC_MESSAGES not present on Windows
	def getlocale(self, x = None):
		assert x is not TestLocale.LC_ALL
		return test_locale
model.locale = TestLocale()

class DummyPackageKit:
	available = False

	def get_candidates(self, package, factory, prefix):
		pass

class DummyHandler(handler.Handler):
	__slots__ = ['ex', 'tb', 'allow_downloads']

	def __init__(self):
		handler.Handler.__init__(self)
		self.ex = None
		self.allow_downloads = False

	def wait_for_blocker(self, blocker):
		self.ex = None
		handler.Handler.wait_for_blocker(self, blocker)
		if self.ex:
			support.raise_with_traceback(self.ex, self.tb)

	def report_error(self, ex, tb = None):
		assert self.ex is None, self.ex
		self.ex = ex
		self.tb = tb

		#import traceback
		#traceback.print_exc()

class DummyKeyInfo:
	def __init__(self, fpr):
		self.fpr = fpr
		self.info = [minidom.parseString('<item vote="bad"/>')]
		self.blocker = None

class TestFetcher:
	def __init__(self, config):
		self.allowed_downloads = set()
		self.allowed_feed_downloads = {}
		self.config = config

	def allow_download(self, digest):
		assert isinstance(self.config.stores, TestStores)
		self.allowed_downloads.add(digest)

	def allow_feed_download(self, url, feed_xml):
		assert isinstance(feed_xml, support.basestring), feed_xml
		self.allowed_feed_downloads[url] = feed_xml

	def download_impls(self, impls, stores):
		@tasks.async
		def fake_download():
			yield
			for impl in impls:
				assert impl.id in self.allowed_downloads, impl
				self.allowed_downloads.remove(impl.id)
				self.config.stores.add_fake(impl.id)
		return fake_download()

	def download_and_import_feed(self, feed_url, iface_cache, force = False):
		@tasks.async
		def fake_download():
			yield
			feed_xml = self.allowed_feed_downloads.get(feed_url, None)
			assert feed_xml, feed_url
			if not isinstance(feed_xml, bytes):
				feed_xml = feed_xml.encode('utf-8')
			self.config.iface_cache.update_feed_from_network(feed_url, feed_xml, int(time.time()))
			del self.allowed_feed_downloads[feed_url]
		return fake_download()

	def fetch_key_info(self, fingerprint):
		return DummyKeyInfo(fingerprint)

class TestStores:
	def __init__(self):
		self.fake_impls = set()

	def add_fake(self, digest):
		self.fake_impls.add(digest)

	def lookup_maybe(self, digests):
		for d in digests:
			if d in self.fake_impls:
				return '/fake_store/' + d
		return None

	def lookup_any(self, digests):
		path = self.lookup_maybe(digests)
		if path:
			return path
		raise NotStored()

class TestConfig:
	freshness = 0
	help_with_testing = False
	network_use = model.network_full
	key_info_server = None
	auto_approve_keys = False
	mirror = None

	def __init__(self):
		self.iface_cache = iface_cache.IfaceCache()
		self.handler = DummyHandler()
		self.stores = Stores()
		self.fetcher = TestFetcher(self)
		self.trust_db = trust.trust_db
		self.trust_mgr = trust.TrustMgr(self)
		self.app_mgr = apps.AppManager(self)

class BaseTest(unittest.TestCase):
	def setUp(self):
		background._detach = throw_background

		warnings.resetwarnings()

		self.config_home = tempfile.mktemp()
		self.cache_home = tempfile.mktemp()
		self.cache_system = tempfile.mktemp()
		self.data_home = tempfile.mktemp()
		self.gnupg_home = tempfile.mktemp()
		os.environ['GNUPGHOME'] = self.gnupg_home
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		os.environ['XDG_CONFIG_DIRS'] = ''
		os.environ['XDG_CACHE_HOME'] = self.cache_home
		os.environ['XDG_CACHE_DIRS'] = self.cache_system
		os.environ['XDG_DATA_HOME'] = self.data_home
		os.environ['XDG_DATA_DIRS'] = ''
		if 'ZEROINSTALL_PORTABLE_BASE' in os.environ:
			del os.environ['ZEROINSTALL_PORTABLE_BASE']
		imp.reload(basedir)
		assert basedir.xdg_config_home == self.config_home

		os.mkdir(self.config_home, 0o700)
		os.mkdir(self.cache_home, 0o700)
		os.mkdir(self.cache_system, 0o500)
		os.mkdir(self.gnupg_home, 0o700)

		if 'DISPLAY' in os.environ:
			del os.environ['DISPLAY']

		self.config = TestConfig()
		iface_cache.iface_cache = self.config.iface_cache

		logging.getLogger().setLevel(logging.WARN)

		download._downloads = {}

		self.old_path = os.environ['PATH']
		os.environ['PATH'] = self.config_home + ':' + dpkgdir + ':' + self.old_path

		distro._host_distribution = distro.DebianDistribution(dpkgdir + '/status')
		distro._host_distribution._packagekit = DummyPackageKit()

		my_dbus.system_services = {}

	def tearDown(self):
		if self.config.handler.ex:
			support.raise_with_traceback(self.config.handler.ex, self.config.handler.tb)

		shutil.rmtree(self.config_home)
		support.ro_rmtree(self.cache_home)
		shutil.rmtree(self.cache_system)
		shutil.rmtree(self.gnupg_home)

		os.environ['PATH'] = self.old_path

	def import_feed(self, url, contents):
		"""contents can be a path or an Element."""
		iface_cache = self.config.iface_cache
		iface_cache.get_interface(url)

		if isinstance(contents, qdom.Element):
			feed = model.ZeroInstallFeed(contents)
		else:
			feed = reader.load_feed(contents)

		iface_cache._feeds[url] = feed
		return feed

	def run_0install(self, args):
		old_stdout = sys.stdout
		old_stderr = sys.stderr
		try:
			sys.stdout = StringIO()
			sys.stderr = StringIO()
			ex = None
			try:
				cmd.main(args, config = self.config)
			except NameError:
				raise
			except SystemExit:
				pass
			except TypeError:
				raise
			except AttributeError:
				raise
			except AssertionError:
				raise
			except ValueError:
				raise
			except Exception as ex2:
				ex = ex2		# Python 3
				raise
			out = sys.stdout.getvalue()
			err = sys.stderr.getvalue()
			if ex is not None:
				err += str(ex.__class__)
		finally:
			sys.stdout = old_stdout
			sys.stderr = old_stderr
		return (out, err)
