#!/usr/bin/env python

from __future__ import print_function

from basetest import BaseTest
import sys, tempfile, os
import unittest
import logging

if sys.version_info[0] > 2:
	from io import StringIO, BytesIO
else:
	from StringIO import StringIO
	BytesIO = StringIO

foo_iface_uri = 'http://foo'

sys.path.insert(0, '..')
from zeroinstall import SafeException
from zeroinstall.support import tasks
from zeroinstall.injector import run, cli, namespaces, qdom, selections
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver

mydir = os.path.abspath(os.path.dirname(__file__))

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
				print("Finished")
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
			except Exception as ex2:
				ex = ex2		# Python 3
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
		self.assertEqual("Finished\n", out)
		cached_ifaces = os.path.join(self.cache_home,
					'0install.net', 'interfaces')

		os.makedirs(cached_ifaces)
		open(os.path.join(cached_ifaces, 'file%3a%2f%2ffoo'), 'w').close()

		out, err = self.run_0launch(['--list'])
		assert not err
		self.assertEqual("file://foo\nFinished\n", out)

		out, err = self.run_0launch(['--list', 'foo'])
		assert not err
		self.assertEqual("file://foo\nFinished\n", out)

		out, err = self.run_0launch(['--list', 'bar'])
		assert not err
		self.assertEqual("Finished\n", out)

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
		self.assertEqual("Would download 'http://foo/d'\nFinished\n", out)
		self.assertEqual("", err)
	
	def testRun(self):
		out, err = self.run_0launch(['Local.xml'])
		self.assertEqual("", out)
		assert "test-echo' does not exist" in err, err

	def testAbsMain(self):
		with tempfile.NamedTemporaryFile(prefix = 'test-', delete = False) as tmp:
			tmp.write((
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group main='/bin/sh'>
   <implementation id='.' version='1'/>
  </group>
</interface>""" % foo_iface_uri).encode('utf-8'))

		driver = Driver(requirements = Requirements(tmp.name), config = self.config)
		try:
			downloaded = driver.solve_and_download_impls()
			if downloaded:
				tasks.wait_for_blocker(downloaded)
			run.execute_selections(driver.solver.selections, [], stores = self.config.stores)
			assert False
		except SafeException as ex:
			assert 'Command path must be relative' in str(ex), ex

	def testOffline(self):
		out, err = self.run_0launch(['--offline', 'http://foo/d'])
		self.assertEqual("Interface 'http://foo/d' has no usable implementations in the cache (and 0install is in off-line mode)\n", err)
		self.assertEqual("", out)

	def testDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', 'http://foo/d'])
		# Uses local copy of GUI
		assert out.startswith("Would execute: "), repr((out, err))
		assert 'basetest.py' in out
		self.assertEqual("", err)

		del os.environ['DISPLAY']
		out, err = self.run_0launch(['--gui', '--dry-run'])
		self.assertEqual("", err)
		self.assertEqual("Finished\n", out)

	def testRefreshDisplay(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--dry-run', '--refresh', 'http://foo/d'])
		assert out.startswith("Would execute: ")
		assert 'basetest.py' in out
		self.assertEqual("", err)
	
	def testNeedDownload(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--download-only', '--dry-run', 'Foo.xml'])
		self.assertEqual("", err)
		self.assertEqual("Finished\n", out)

	def testSelectOnly(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0launch(['--get-selections', '--select-only', 'Hello.xml'])
		self.assertEqual("", err)

		assert out.endswith("Finished\n")
		out = out[:-len("Finished\n")]

		root = qdom.parse(BytesIO(str(out).encode('utf-8')))
		self.assertEqual(namespaces.XMLNS_IFACE, root.uri)
		sels = selections.Selections(root)
		sel,= sels.selections.values()
		self.assertEqual("sha1=3ce644dc725f1d21cfcf02562c76f375944b266a", sel.id)

	def testHello(self):
		out, err = self.run_0launch(['--dry-run', 'Foo.xml'])
		self.assertEqual("", err)
		assert out.startswith("Would execute: ")

		out, err = self.run_0launch(['Foo.xml'])
		# (Foo.xml tries to run a directory; plash gives a different error)
		assert "Permission denied" in err or "Is a directory" in err

	def testSource(self):
		out, err = self.run_0launch(['--dry-run', '--source', '--not-before=1', 'Source.xml'])
		self.assertEqual("", err)
		assert 'Compiler.xml' in out
	
	def testRanges(self):
		out, err = self.run_0launch(['--get-selections', '--before=1', '--not-before=0.2', 'Foo.xml'])
		assert 'tests/rpm' in out, out
		self.assertEqual("", err)
	
	def testLogging(self):
		log = logging.getLogger()
		log.addFilter(silenceLogger)

		out, err = self.run_0launch(['-v', '--list', 'UNKNOWN'])
		self.assertEqual(logging.INFO, log.level)

		out, err = self.run_0launch(['-vv', '--version'])
		self.assertEqual(logging.DEBUG, log.level)

		log.removeFilter(silenceLogger)
		log.setLevel(logging.WARN)
	
	def testHelp2(self):
		out, err = self.run_0launch(['--help'])
		self.assertEqual("", err)
		assert 'options:' in out.lower()

		out, err = self.run_0launch([])
		self.assertEqual("", err)
		assert 'options:' in out.lower()
	
	def testBadFD(self):
		copy = os.dup(1)
		try:
			os.close(1)
			cli.main(['--list', 'UNKNOWN'])
		finally:
			os.dup2(copy, 1)

	def testShow(self):
		command_feed = os.path.join(mydir, 'Command.xml')
		out, err = self.run_0launch(['--show', command_feed])
		self.assertEqual("", err)
		assert 'Local.xml' in out, out

if __name__ == '__main__':
	unittest.main()
