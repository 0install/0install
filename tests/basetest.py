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
from zeroinstall.injector import namespaces, qdom
from zeroinstall.injector import iface_cache, download, distro
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False
from zeroinstall import support
from zeroinstall.support import basedir

dpkgdir = os.path.join(os.path.dirname(__file__), 'dpkg')

empty_feed = qdom.parse(StringIO.StringIO("""<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>
<name>Empty</name>
<summary>just for testing</summary>
</interface>"""))

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
		namespaces.injector_gui_uri = os.path.join(os.path.dirname(__file__), 'test-gui.xml')

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
