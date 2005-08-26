#!/usr/bin/env python2.3
import sys, tempfile, os, shutil, imp
from StringIO import StringIO
import unittest

foo_iface_uri = 'http://foo'

sys.path.insert(0, '..')
from zeroinstall.injector import trust, basedir, autopolicy, namespaces, model, iface_cache

class TestLaunch(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		self.cache_home = tempfile.mktemp()
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		os.environ['XDG_CACHE_HOME'] = self.cache_home
		reload(basedir)
		iface_cache.iface_cache.__init__()

		os.mkdir(self.config_home, 0700)
		os.mkdir(self.cache_home, 0700)
		if os.environ.has_key('DISPLAY'):
			del os.environ['DISPLAY']
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
		shutil.rmtree(self.cache_home)

	def cache_iface(self, name, data):
		cached_ifaces = basedir.save_cache_path('0install.net',
							'interfaces')

		f = file(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def run_0launch(self, args):
		sys.argv = ['0launch'] + args
		old_stdout = sys.stdout
		old_stderr = sys.stderr
		try:
			sys.stdout = StringIO()
			sys.stderr = StringIO()
			ex = None
			try:
				imp.load_source('launch', '../0launch')
				print "Finished"
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
		out, err = self.run_0launch([])
		assert out.startswith("usage:")
		assert not err
	
	def testList(self):
		out, err = self.run_0launch(['--list'])
		assert not err
		self.assertEquals("", out)
		cached_ifaces = os.path.join(self.cache_home,
					'0install.net', 'interfaces')

		os.makedirs(cached_ifaces)
		file(os.path.join(cached_ifaces, 'file%3a%2f%2ffoo'), 'w').close()

		out, err = self.run_0launch(['--list'])
		assert not err
		self.assertEquals("file://foo\n", out)

		out, err = self.run_0launch(['--list', 'foo'])
		assert not err
		self.assertEquals("file://foo\n", out)

		out, err = self.run_0launch(['--list', 'bar'])
		assert not err
		self.assertEquals("", out)

		out, err = self.run_0launch(['--list', 'one', 'two'])
		assert not err
		assert out.startswith("usage:")
	
	def testVersion(self):
		out, err = self.run_0launch(['--version'])
		assert not err
		assert out.startswith("0launch (zero-install)")

	def testInvalid(self):
		a = tempfile.NamedTemporaryFile()
		out, err = self.run_0launch(['-q', a.name])
		assert err
	
	def testOK(self):
		out, err = self.run_0launch(['--dry-run', 'http://foo'])
		self.assertEquals("Would download 'http://foo'\n", out)
		self.assertEquals("", err)
	
	def testDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', 'http://foo'])
		self.assertEquals("Would download 'http://0install.net/2005/interfaces/injector-gui'\n",
				   out)
		self.assertEquals("", err)

	def testRefreshDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', '--download-only',
				     '--refresh', 'http://foo'])
		self.assertEquals("Would download 'http://0install.net/2005/interfaces/injector-gui'\n",
				  out)
		self.assertEquals("", err)
	
	def testNeedDownload(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri)
		policy.save_config()
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--download-only', '--dry-run', 'Foo.xml'])
		self.assertEquals("", err)
		self.assertEquals("Finished\n", out)

	def testHello(self):
		out, err = self.run_0launch(['--dry-run', 'Foo.xml'])
		self.assertEquals("", err)
		assert out.startswith("Would execute: ")

		out, err = self.run_0launch(['Foo.xml'])
		# (Foo.xml tries to run a directory)
		assert "Permission denied" in err

suite = unittest.makeSuite(TestLaunch)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
