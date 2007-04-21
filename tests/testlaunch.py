#!/usr/bin/env python2.3
from basetest import BaseTest
import sys, tempfile, os, shutil, imp
from StringIO import StringIO
import unittest
import logging

foo_iface_uri = 'http://foo'

sys.path.insert(0, '..')
from zeroinstall.injector import trust, basedir, autopolicy, namespaces, model, iface_cache, cli
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False

class SilenceLogger(logging.Filter):
	def filter(self, record):
		return 0
silenceLogger = SilenceLogger()

class TestLaunch(BaseTest):
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
			except AssertionError:
				raise
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
		assert out.lower().startswith("usage:")
		assert not err
	
	def testList(self):
		out, err = self.run_0launch(['--list'])
		assert not err
		self.assertEquals("Finished\n", out)
		cached_ifaces = os.path.join(self.cache_home,
					'0install.net', 'interfaces')

		os.makedirs(cached_ifaces)
		file(os.path.join(cached_ifaces, 'file%3a%2f%2ffoo'), 'w').close()

		out, err = self.run_0launch(['--list'])
		assert not err
		self.assertEquals("file://foo\nFinished\n", out)

		out, err = self.run_0launch(['--list', 'foo'])
		assert not err
		self.assertEquals("file://foo\nFinished\n", out)

		out, err = self.run_0launch(['--list', 'bar'])
		assert not err
		self.assertEquals("Finished\n", out)

		out, err = self.run_0launch(['--list', 'one', 'two'])
		assert not err
		assert out.lower().startswith("usage:")
	
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
		self.assertEquals("Would download 'http://foo'\nFinished\n", out)
		self.assertEquals("", err)
	
	def testDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', 'http://foo'])
		# Uses local copy of GUI
		assert out.startswith("Would execute: ")
		assert 'basetest.py' in out
		self.assertEquals("", err)

		del os.environ['DISPLAY']
		out, err = self.run_0launch(['--gui', '--dry-run'])
		self.assertEquals("", err)
		self.assertEquals("Finished\n", out)

	def testRefreshDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', '--refresh', 'http://foo'])
		assert out.startswith("Would execute: ")
		assert 'basetest.py' in out
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
		# (Foo.xml tries to run a directory; plash gives a different error)
		assert "Permission denied" in err or "Is a directory" in err

	def testSource(self):
		out, err = self.run_0launch(['--dry-run', '--source', 'Source.xml'])
		self.assertEquals("", err)
		assert 'Compiler.xml' in out
	
	def testLogging(self):
		log = logging.getLogger()
		log.addFilter(silenceLogger)

		out, err = self.run_0launch(['-v', '--list', 'UNKNOWN'])
		self.assertEquals(logging.INFO, log.level)

		out, err = self.run_0launch(['-vv', '--version'])
		self.assertEquals(logging.DEBUG, log.level)

		log.removeFilter(silenceLogger)
		log.setLevel(logging.WARN)
	
	def testHelp(self):
		out, err = self.run_0launch(['--help'])
		self.assertEquals("", err)
		assert 'options:' in out.lower()

		out, err = self.run_0launch([])
		self.assertEquals("", err)
		assert 'options:' in out.lower()
	
	def testBadFD(self):
		copy = os.dup(1)
		try:
			os.close(1)
			cli.main(['--list', 'UNKNOWN'])
		finally:
			os.dup2(copy, 1)

suite = unittest.makeSuite(TestLaunch)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
