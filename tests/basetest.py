#!/usr/bin/env python
import locale
locale.setlocale(locale.LC_ALL, 'C')
import sys, tempfile, os, shutil, imp
import unittest, subprocess
import logging
import warnings
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

if 'ZEROINSTALL_CRASH_LOGS' in os.environ: del os.environ['ZEROINSTALL_CRASH_LOGS']

sys.path.insert(0, '..')
from zeroinstall.injector import qdom, namespaces
from zeroinstall.injector import iface_cache, download, model, handler, reader, trust
from zeroinstall import support, cmd
from zeroinstall.support import basedir

def skipIf(condition, reason):
	def wrapped(underlying):
		if condition:
			if hasattr(underlying, 'func_name'):
				print("Skipped %s: %s" % (underlying.func_name, reason))	# Python 2
			else:
				print("Skipped %s: %s" % (underlying.__name__, reason))		# Python 3
			def run(self): pass
			return run
		else:
			return underlying
	return wrapped

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
ocaml_0install = os.path.join(mydir, '..', 'build', 'ocaml', '0install')

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

class DummyHandler(handler.Handler):
	__slots__ = ['ex', 'tb', 'allow_downloads']

	def __init__(self):
		handler.Handler.__init__(self)
		self.ex = None
		self.allow_downloads = False

	def report_error(self, ex, tb = None):
		assert self.ex is None, self.ex
		self.ex = ex
		self.tb = tb

		#import traceback
		#traceback.print_exc()

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
		self.trust_db = trust.trust_db

class BaseTest(unittest.TestCase):
	def setUp(self):
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

		my_dbus.system_services = {}

		trust.trust_db.watchers = []
		trust.trust_db.keys = None
		trust.trust_db._dry_run = False

	def tearDown(self):
		if self.config.handler.ex:
			support.raise_with_traceback(self.config.handler.ex, self.config.handler.tb)

		shutil.rmtree(self.config_home)
		support.ro_rmtree(self.cache_home)
		shutil.rmtree(self.cache_system)
		shutil.rmtree(self.gnupg_home)

		os.environ['PATH'] = self.old_path

	def run_ocaml(self, args, stdin = None, stderr = subprocess.PIPE, binary = False):
		child = subprocess.Popen([ocaml_0install] + args,
				stdin = subprocess.PIPE if stdin is not None else None,
				stdout = subprocess.PIPE, stderr = stderr, universal_newlines = not binary)
		out, err = child.communicate(stdin)
		status = child.wait()
		if status:
			msg = "Exit status: %d\n" % status
			if binary:
				msg = msg.encode('utf-8')
			err += msg
		return out, err

	def import_feed(self, url, contents):
		"""contents can be a path or an Element."""
		iface_cache = self.config.iface_cache
		iface_cache.get_interface(url)

		if isinstance(contents, qdom.Element):
			feed = model.ZeroInstallFeed(contents)
		else:
			feed = reader.load_feed(contents)

		iface_cache._feeds[url] = feed

		xml = qdom.to_UTF8(feed.feed_element)
		upstream_dir = basedir.save_cache_path(namespaces.config_site, 'interfaces')
		cached = os.path.join(upstream_dir, model.escape(url))
		with open(cached, 'wb') as stream:
			stream.write(xml)

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
