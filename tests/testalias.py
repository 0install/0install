#!/usr/bin/env python
from basetest import BaseTest, StringIO
import sys, tempfile, os
import unittest

sys.path.insert(0, '..')

from zeroinstall import alias

expected_script = """#!/bin/sh
exec 0launch 'http://example.com/foo.xml' "$@"
"""

old_script = """#!/bin/sh
if [ "$*" = "--versions" ]; then
  exec 0launch -gd 'http://example.com/foo.xml' "$@"
else
  exec 0launch  'http://example.com/foo.xml' "$@"
fi
 """

expected_script_main = """#!/bin/sh
exec 0launch --main 'a'\\'''\\''\\test' 'http://example.com/foo.xml' "$@"
"""

expected_script_command = """#!/bin/sh
exec 0launch --command 'a'\\'''\\''\\test' 'http://example.com/foo.xml' "$@"
"""

old_script_main = """#!/bin/sh
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
		self.assertEqual(expected_script, buf.getvalue())

		buf = StringIO()
		alias.write_script(buf, 'http://example.com/foo.xml', 'a\'\'\\test')
		self.assertEqual(expected_script_main, buf.getvalue())

		buf = StringIO()
		alias.write_script(buf, 'http://example.com/foo.xml', command = 'a\'\'\\test')
		self.assertEqual(expected_script_command, buf.getvalue())

	def testParse(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write(expected_script)
		tmp.flush()
		tmp.seek(0)
		uri, main = alias.parse_script(tmp.name)
		self.assertEqual('http://example.com/foo.xml', uri)
		self.assertEqual(None, main)

		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write(expected_script_main)
		tmp.flush()
		tmp.seek(0)
		uri, main = alias.parse_script(tmp.name)
		self.assertEqual('http://example.com/foo.xml', uri)
		self.assertEqual('a\'\'\\test', main)

		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write(expected_script_command)
		tmp.flush()
		tmp.seek(0)
		info = alias.parse_script(tmp.name)
		self.assertEqual('http://example.com/foo.xml', info.uri)
		self.assertEqual('a\'\'\\test', info.command)
		self.assertEqual(None, info.main)

	def testParseOld(self):
		with tempfile.NamedTemporaryFile(mode = 'wt') as tmp:
			tmp.write(old_script)
			tmp.flush()
			tmp.seek(0)
			uri, main = alias.parse_script(tmp.name)
			self.assertEqual('http://example.com/foo.xml', uri)
			self.assertEqual(None, main)

		with tempfile.NamedTemporaryFile(mode = 'wt') as tmp:
			tmp.write(old_script_main)
			tmp.flush()
			tmp.seek(0)
			uri, main = alias.parse_script(tmp.name)
			self.assertEqual('http://example.com/foo.xml', uri)
			self.assertEqual('a\'\'\\test', main)
	
	def testParseException(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wb', delete = False)
		tmp.write(bytes([240]))
		tmp.close()
		try:
			alias.parse_script(tmp.name)
			assert False
		except alias.NotAnAliasScript:
			pass
		os.unlink(tmp.name)

		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write('hi' + expected_script)
		tmp.flush()
		tmp.seek(0)
		try:
			alias.parse_script(tmp.name)
			assert False
		except alias.NotAnAliasScript:
			pass

		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write(expected_script_command.replace('command', 'bob'))
		tmp.flush()
		tmp.seek(0)
		try:
			alias.parse_script(tmp.name)
			assert False
		except alias.NotAnAliasScript as ex:
			assert 'does not look like a script created by 0alias' in str(ex)
			pass

if __name__ == '__main__':
	unittest.main()
