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
from zeroinstall.injector import trust, basedir

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
			imp.load_source('launch', '../0launch')
			assert 0
		except SystemExit:
			pass
		out = sys.stdout.getvalue()
		err = sys.stderr.getvalue()
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

suite = unittest.makeSuite(TestLaunch)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
