#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall import alias

expected_script = """#!/bin/sh
if [ "$*" = "--versions" ]; then
  exec 0launch -gd 'http://example.com/foo.xml' "$@"
else
  exec 0launch  'http://example.com/foo.xml' "$@"
fi
"""

expected_script_main = """#!/bin/sh
if [ "$*" = "--versions" ]; then
  exec 0launch -gd 'http://example.com/foo.xml' "$@"
else
  exec 0launch --main 'a'\\'''\\''\\test' 'http://example.com/foo.xml' "$@"
fi
"""

class TestAlias(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
	
	def testWrite(self):
		buf = StringIO()
		alias.write_script(buf, 'http://example.com/foo.xml', None)
		self.assertEquals(expected_script, buf.getvalue())

		buf = StringIO()
		alias.write_script(buf, 'http://example.com/foo.xml', 'a\'\'\\test')
		self.assertEquals(expected_script_main, buf.getvalue())

	def testParse(self):
		tmp = tempfile.NamedTemporaryFile()
		tmp.write(expected_script)
		tmp.flush()
		tmp.seek(0)
		uri, main = alias.parse_script(tmp.name)
		self.assertEquals('http://example.com/foo.xml', uri)
		self.assertEquals(None, main)

		tmp = tempfile.NamedTemporaryFile()
		tmp.write(expected_script_main)
		tmp.flush()
		tmp.seek(0)
		uri, main = alias.parse_script(tmp.name)
		self.assertEquals('http://example.com/foo.xml', uri)
		self.assertEquals('a\'\'\\test', main)
	
	def testParseException(self):
		tmp = tempfile.NamedTemporaryFile()
		tmp.write('hi' + expected_script)
		tmp.flush()
		tmp.seek(0)
		try:
			alias.parse_script(tmp.name)
			assert False
		except alias.NotAnAliasScript:
			pass

suite = unittest.makeSuite(TestAlias)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
