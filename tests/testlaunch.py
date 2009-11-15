#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile, os
from StringIO import StringIO
import unittest
import logging

foo_iface_uri = 'http://foo'

sys.path.insert(0, '..')
from zeroinstall.injector import autopolicy, model, cli
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False
from zeroinstall.support import basedir

class SilenceLogger(logging.Filter):
	def filter(self, record):
		return 0
silenceLogger = SilenceLogger()

class TestLaunch(BaseTest):
	def run_0launch(self, args):
		old_stdout = sys.stdout
		old_stderr = sys.stderr
		try:
			sys.stdout = StringIO()
			sys.stderr = StringIO()
			ex = None
			try:
				cli.main(args)
				print "Finished"
			except NameError:
				raise
			except SystemExit:
				pass
			except TypeError:
				raise
			except AttributeError:
				raise
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
		out, err = self.run_0launch(['--dry-run', 'http://foo/d'])
		self.assertEquals("Would download 'http://foo/d'\nFinished\n", out)
		self.assertEquals("", err)
	
	def testRun(self):
		out, err = self.run_0launch(['Local.xml'])
		self.assertEquals("", out)
		assert "test-echo' does not exist" in err

	def testOffline(self):
		out, err = self.run_0launch(['--offline', 'http://foo/d'])
		self.assertEquals("Can't find all required implementations:\n- <Interface http://foo/d> -> None\n", err)
		self.assertEquals("", out)

	def testDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', 'http://foo/d'])
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
		out, err = self.run_0launch(['--dry-run', '--refresh', 'http://foo/d'])
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
	
	def testRanges(self):
		out, err = self.run_0launch(['--dry-run', '--before=1', '--not-before=0.2', 'Foo.xml'])
		assert 'tests/two' in err, err
		self.assertEquals("", out)
	
	def testLogging(self):
		log = logging.getLogger()
		log.addFilter(silenceLogger)

		out, err = self.run_0launch(['-v', '--list', 'UNKNOWN'])
		self.assertEquals(logging.INFO, log.level)

		out, err = self.run_0launch(['-vv', '--version'])
		self.assertEquals(logging.DEBUG, log.level)

		log.removeFilter(silenceLogger)
		log.setLevel(logging.WARN)
	
	def testHelp2(self):
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
