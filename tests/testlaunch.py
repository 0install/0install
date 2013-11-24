#!/usr/bin/env python

from __future__ import print_function

from basetest import BaseTest, StringIO
import sys, tempfile, os, imp, subprocess
import unittest
import logging

os.environ["http_proxy"] = "localhost:8000"
foo_iface_uri = 'http://foo'

sys.path.insert(0, '..')

mydir = os.path.abspath(os.path.dirname(__file__))

class SilenceLogger(logging.Filter):
	def filter(self, record):
		return 0
silenceLogger = SilenceLogger()

ocaml_0launch = os.path.join(mydir, '..', 'build', 'ocaml', '0launch')
ocaml_0install = os.path.join(mydir, '..', 'build', 'ocaml', '0install')

class TestLaunch(BaseTest):
	def run_0launch(self, args, stdin = None, stderr = subprocess.PIPE):
		child = subprocess.Popen([ocaml_0launch] + args,
				stdin = subprocess.PIPE if stdin is not None else None,
				stdout = subprocess.PIPE, stderr = stderr, universal_newlines = True)
		out, err = child.communicate(stdin)
		if child.wait() == 0: out += 'Finished\n'
		return out, err

	def run_0install(self, args, stdin = None, stderr = subprocess.PIPE):
		child = subprocess.Popen([ocaml_0install] + args,
				stdin = subprocess.PIPE if stdin is not None else None,
				stdout = subprocess.PIPE, stderr = stderr, universal_newlines = True)
		out, err = child.communicate(stdin)
		status = child.wait()
		if status:
			err += "Exit status: %d\n" % status
		else:
			out += "Finished\n"
		return out, err

	def testHelp(self):
		out, err = self.run_0launch([])
		assert out.lower().startswith("usage:")
		assert not err
	
	def testList(self):
		out, err = self.run_0install(['list'])
		assert not err
		self.assertEqual("Finished\n", out)
		cached_ifaces = os.path.join(self.cache_home,
					'0install.net', 'interfaces')

		os.makedirs(cached_ifaces)
		open(os.path.join(cached_ifaces, 'file%3a%2f%2ffoo'), 'w').close()

		out, err = self.run_0install(['list'])
		assert not err
		self.assertEqual("file://foo\nFinished\n", out)

		out, err = self.run_0install(['list', 'foo'])
		assert not err
		self.assertEqual("file://foo\nFinished\n", out)

		out, err = self.run_0install(['list', 'bar'])
		assert not err
		self.assertEqual("Finished\n", out)

		out, err = self.run_0install(['list', 'one', 'two'])
		assert "Exit status: 1" in err, err
		assert out.lower().startswith("usage:")
	
	def testVersion(self):
		out, err = self.run_0launch(['--version'])
		assert not err, err
		assert out.startswith("0launch (zero-install)")

	def testInvalid(self):
		a = tempfile.NamedTemporaryFile()
		out, err = self.run_0launch(['-q', a.name])
		assert err
	
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

		out, err = self.run_0install(['run', tmp.name])
		assert not out, out
		assert "Exit status: 1" in err, err
		assert "Absolute path '/bin/sh' in <group>" in err, err

	def testOffline(self):
		out, err = self.run_0launch(['--offline', 'http://foo/d'])
		self.assertEqual("Can't find all required implementations:\n"
				 "- http://foo/d -> (problem)\n"
				 "    No known implementations at all\n"
				 "Note: 0install is in off-line mode\n", err)
		self.assertEqual("", out)

	def testNeedDownload(self):
		os.environ['DISPLAY'] = ':foo'
		out, err = self.run_0install(['download', '--dry-run', 'Foo.xml'])
		self.assertEqual("", err)
		self.assertEqual("Finished\n", out)

	def testHello(self):
		out, err = self.run_0launch(['--dry-run', 'Foo.xml'])
		self.assertEqual("", err)
		assert out.startswith("[dry-run] would execute: ")

		out, err = self.run_0launch(['Foo.xml'])
		# (Foo.xml tries to run a directory; plash gives a different error)
		assert "Permission denied" in err or "Is a directory" in err

	def testRanges(self):
		out, err = self.run_0install(['select', '--before=1', '--not-before=0.2', 'Foo.xml'])
		assert 'tests/rpm' in out, out
		self.assertEqual("", err)
	
	def testLogging(self):
		out, err = self.run_0install(['-v', 'list', 'UNKNOWN'])
		assert "0install (OCaml version): verbose mode on" in err, err
	
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
			out, err = self.run_0install(['list', 'UNKNOWN'])
			assert out == "Finished\n", out
			assert not err, err
		finally:
			os.dup2(copy, 1)

	def testShow(self):
		command_feed = os.path.join(mydir, 'Command.xml')
		out, err = self.run_0install(['select', command_feed])
		self.assertEqual("", err)
		assert 'Local.xml' in out, out

	def testExecutables(self):
		# Check top-level scripts are readable (detects white-space errors)
		for script in ['0install-python-fallback', '0alias']:
			path = os.path.join('..', script)

			old_stdout = sys.stdout
			old_stderr = sys.stderr
			old_argv = sys.argv
			try:
				sys.argv = [script, '--help']
				sys.stderr = sys.stdout = StringIO()

				imp.load_source(script, path)
			except SystemExit:
				out = sys.stdout.getvalue()
				assert 'Usage: ' in out, (script, out)
			else:
				assert False
			finally:
				sys.stdout = old_stdout
				sys.stderr = old_stderr
				sys.argv = old_argv


if __name__ == '__main__':
	unittest.main()
