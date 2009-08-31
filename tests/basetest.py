#!/usr/bin/env python2.5
import sys, tempfile, os, shutil, StringIO
import unittest
import logging
import warnings

# It's OK to test deprecated features
warnings.filterwarnings("ignore", category = DeprecationWarning)

# Catch silly mistakes...
os.environ['HOME'] = '/home/idontexist'

sys.path.insert(0, '..')
from zeroinstall.injector import qdom
from zeroinstall.injector import iface_cache, download, distro
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False
from zeroinstall import support, helpers
from zeroinstall.support import basedir

dpkgdir = os.path.join(os.path.dirname(__file__), 'dpkg')

empty_feed = qdom.parse(StringIO.StringIO("""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Empty</name>
<summary>just for testing</summary>
</interface>"""))

mydir = os.path.dirname(__file__)

# Catch us trying to run the GUI and return a dummy string instead
old_execvp = os.execvp
def test_execvp(prog, args):
	if prog.endswith('/0launch-gui'):
		prog = os.path.join(mydir, 'test-gui')
	return old_execvp(prog, args)

os.execvp = test_execvp

class BaseTest(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		self.cache_home = tempfile.mktemp()
		self.cache_system = tempfile.mktemp()
		self.gnupg_home = tempfile.mktemp()
		os.environ['GNUPGHOME'] = self.gnupg_home
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		os.environ['XDG_CACHE_HOME'] = self.cache_home
		os.environ['XDG_CACHE_DIRS'] = self.cache_system
		reload(basedir)
		assert basedir.xdg_config_home == self.config_home
		iface_cache.iface_cache.__init__()

		os.mkdir(self.config_home, 0700)
		os.mkdir(self.cache_home, 0700)
		os.mkdir(self.cache_system, 0500)
		os.mkdir(self.gnupg_home, 0700)

		if os.environ.has_key('DISPLAY'):
			del os.environ['DISPLAY']

		logging.getLogger().setLevel(logging.WARN)

		download._downloads = {}

		self.old_path = os.environ['PATH']
		os.environ['PATH'] = dpkgdir + ':' + self.old_path

		distro._host_distribution = distro.DebianDistribution(dpkgdir)
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
		support.ro_rmtree(self.cache_home)
		shutil.rmtree(self.cache_system)
		shutil.rmtree(self.gnupg_home)

		os.environ['PATH'] = self.old_path
