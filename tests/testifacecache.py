#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest
import data
from logging import getLogger, DEBUG, INFO
#getLogger().setLevel(DEBUG)

sys.path.insert(0, '..')
from zeroinstall.injector import basedir, download, model, gpg
from zeroinstall.injector.namespaces import *
from zeroinstall.injector.iface_cache import iface_cache

class TestIfaceCache(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		self.cache_home = tempfile.mktemp()
		self.gnupg_home = tempfile.mktemp()
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		os.environ['XDG_CACHE_HOME'] = self.cache_home
		os.environ['GNUPGHOME'] = self.gnupg_home
		reload(basedir)

		os.mkdir(self.config_home, 0700)
		os.mkdir(self.cache_home, 0700)
		os.mkdir(self.gnupg_home, 0700)

		iface_cache._interfaces = {}
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
		shutil.rmtree(self.cache_home)
		shutil.rmtree(self.gnupg_home)

	def testList(self):
		self.assertEquals([], iface_cache.list_all_interfaces())
		iface_dir = basedir.save_cache_path(config_site, 'interfaces')
		file(os.path.join(iface_dir, 'http%3a%2f%2ffoo'), 'w').close()
		self.assertEquals(['http://foo'],
				iface_cache.list_all_interfaces())
		# TODO: test overrides

	def testCheckSigned(self):
		new, iface = iface_cache.get_interface('http://foo')
		assert new
		src = tempfile.TemporaryFile()

		# Unsigned
		src.write("hello")
		src.flush()
		src.seek(0)
		try:
			iface_cache.check_signed_data(iface, src, None)
			assert 0
		except model.SafeException:
			pass

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)

		# Signed
		src.seek(0)
		src.write(data.foo_signed)
		src.flush()
		src.seek(0)
		iface_cache.check_signed_data(iface, src, None)
		self.assertEquals(['http://foo'],
				iface_cache.list_all_interfaces())

suite = unittest.makeSuite(TestIfaceCache)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
