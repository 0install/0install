#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest

sys.path.insert(0, '..')

gnupg_home = tempfile.mktemp()
os.environ['GNUPGHOME'] = gnupg_home

config_home = tempfile.mktemp()
cache_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home
os.environ['XDG_CACHE_HOME'] = cache_home

from zeroinstall.injector import model, basedir, autopolicy
reload(basedir)

foo_iface_signed = tempfile.NamedTemporaryFile()
foo_iface_uri = foo_iface_signed.name

class TestAutoPolicy(unittest.TestCase):
	def setUp(self):
		os.mkdir(config_home, 0700)
		os.mkdir(cache_home, 0700)
		if os.environ.has_key('DISPLAY'):
			del os.environ['DISPLAY']
	
	def tearDown(self):
		shutil.rmtree(config_home)
		shutil.rmtree(cache_home)
	
	def cache_iface(self, name, data):
		cached_ifaces = basedir.save_cache_path('0install.net',
							'interfaces')

		f = file(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def testNoNeedDl(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri,
				False, False, False)
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
	
	def testExec(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri,
				False, False, False)
		policy.freshness = 0


suite = unittest.makeSuite(TestAutoPolicy)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
