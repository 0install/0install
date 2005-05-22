#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest
from logging import getLogger, DEBUG, INFO
#getLogger().setLevel(DEBUG)

sys.path.insert(0, '..')

config_home = tempfile.mktemp()
cache_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home
os.environ['XDG_CACHE_HOME'] = cache_home

from zeroinstall.injector import model, basedir, autopolicy, gpg, iface_cache
import data
reload(basedir)

foo_iface_uri = 'http://foo'

class TestAutoPolicy(unittest.TestCase):
	def setUp(self):
		os.mkdir(config_home, 0700)
		os.mkdir(cache_home, 0700)
		if os.environ.has_key('DISPLAY'):
			del os.environ['DISPLAY']
		self.gnupg_home = tempfile.mktemp()
		os.environ['GNUPGHOME'] = self.gnupg_home
		os.mkdir(self.gnupg_home, 0700)
		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		iface_cache.iface_cache._interfaces = {}
	
	def tearDown(self):
		shutil.rmtree(config_home)
		shutil.rmtree(cache_home)
		shutil.rmtree(self.gnupg_home)
	
	def cache_iface(self, name, data):
		cached_ifaces = basedir.save_cache_path('0install.net',
							'interfaces')

		f = file(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def testNoNeedDl(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri, quiet = False,
						download_only = False)
		policy.freshness = 0
		assert policy.need_download()
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
</interface>""" % foo_iface_uri)
		assert not policy.need_download()
	
	def testDownload(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri, False, False)
		policy.freshness = 0
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 main='ThisBetterNotExist'
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation version='1.0' id='/bin'/>
</interface>""" % foo_iface_uri)
		try:
			policy.download_and_execute(['Hello'])
			assert 0
		except model.SafeException, ex:
			assert "ThisBetterNotExist" in str(ex)

suite = unittest.makeSuite(TestAutoPolicy)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
