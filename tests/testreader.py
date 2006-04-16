#!/usr/bin/env python2.3
import sys, tempfile, os, shutil, logging
from StringIO import StringIO
import unittest
from logging import getLogger, DEBUG, INFO

sys.path.insert(0, '..')

config_home = tempfile.mktemp()
cache_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home
os.environ['XDG_CACHE_HOME'] = cache_home

from zeroinstall import NeedDownload
from zeroinstall.injector import model, basedir, autopolicy, gpg, iface_cache, namespaces, reader
import data
reload(basedir)

foo_iface_uri = 'http://foo'

logger = logging.getLogger()

class TestReader(unittest.TestCase):
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
	
	def write_with_version(self, version):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s" %s
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
</interface>""" % (foo_iface_uri, version))
		tmp.flush()
		return tmp
	
	def testNoVersion(self):
		tmp = self.write_with_version('')
		reader.check_readable(foo_iface_uri, tmp.name)
	
	def testNewEnough(self):
		tmp = self.write_with_version('min-injector-version="0.19"')
		reader.check_readable(foo_iface_uri, tmp.name)
	
	def testTooOld(self):
		tmp = self.write_with_version('min-injector-version="1000"')
		try:
			reader.check_readable(foo_iface_uri, tmp.name)
		except reader.InvalidInterface, ex:
			assert "1000" in str(ex)
	
suite = unittest.makeSuite(TestReader)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
