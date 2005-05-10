#!/usr/bin/env python2.3
import sys, tempfile, os, shutil, imp
from StringIO import StringIO
import unittest

config_home = tempfile.mktemp()
cache_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home
os.environ['XDG_CACHE_HOME'] = cache_home

cached_ifaces = os.path.join(cache_home, '0install.net', 'interfaces')

thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

sys.path.insert(0, '..')
from zeroinstall.injector import trust, basedir, autopolicy

reload(basedir)

class TestLaunch(unittest.TestCase):
	def setUp(self):
		os.mkdir(config_home, 0700)
		os.mkdir(cache_home, 0700)
		if os.environ.has_key('DISPLAY'):
			del os.environ['DISPLAY']
	
	def tearDown(self):
		shutil.rmtree(config_home)
		shutil.rmtree(cache_home)

	def run(self, args):
		sys.argv = ['0launch'] + args
		old_stdout = sys.stdout
		old_stderr = sys.stderr
		try:
			sys.stdout = StringIO()
			sys.stderr = StringIO()
			ex = None
			try:
				imp.load_source('launch', '../0launch')
				assert 0
			except SystemExit:
				pass
			except Exception, ex:
				pass
			out = sys.stdout.getvalue()
			err = sys.stderr.getvalue()
			if ex is not None:
				err += str(ex.__class__)
		finally:
			sys.stdout = old_stdout
			sys.stderr = old_stderr
		return (out, err)

	def testHelp(self):
		out, err = self.run([])
		assert out.startswith("usage:")
		assert not err
	
	def testList(self):
		out, err = self.run(['--list'])
		assert not err
		self.assertEquals("", out)
		os.makedirs(cached_ifaces)
		file(os.path.join(cached_ifaces, 'file%3a%2f%2ffoo'), 'w').close()

		out, err = self.run(['--list'])
		assert not err
		self.assertEquals("file://foo\n", out)

		out, err = self.run(['--list', 'foo'])
		assert not err
		self.assertEquals("file://foo\n", out)

		out, err = self.run(['--list', 'bar'])
		assert not err
		self.assertEquals("", out)

		out, err = self.run(['--list', 'one', 'two'])
		assert not err
		assert out.startswith("usage:")
	
	def testVersion(self):
		out, err = self.run(['--version'])
		assert not err
		assert out.startswith("0launch (zero-install)")

	def testInvalid(self):
		a = tempfile.NamedTemporaryFile()
		out, err = self.run(['-q', a.name])
		assert err
	
	def testOK(self):
		out, err = self.run(['--dry-run', 'http://foo'])
		self.assertEquals("", out)
		self.assertEquals("zeroinstall.injector.autopolicy.NeedDownload", err)
	
	def testDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run(['--dry-run', 'http://foo'])
		self.assertEquals("Need to download; switching to GUI mode\n", out)
		self.assertEquals("zeroinstall.injector.autopolicy.NeedDownload", err)

	def testRefreshDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run(['--dry-run', '--download-only',
				     '--refresh', 'http://foo'])
		self.assertEquals("", out)
		self.assertEquals("zeroinstall.injector.autopolicy.NeedDownload", err)

suite = unittest.makeSuite(TestLaunch)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
