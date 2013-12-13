#!/usr/bin/env python
from basetest import BaseTest
import sys, os, subprocess, shlex
import unittest

sys.path.insert(0, '..')
from zeroinstall import support

mydir = os.path.dirname(__file__)

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

_template = '''#!/bin/sh
exec 0launch %s'%s' "$@"
'''

def write_script(stream, interface_uri, main = None, command = None):
	"""Write a shell script to stream that will launch the given program.
	@param stream: the stream to write to
	@type stream: file
	@param interface_uri: the program to launch
	@type interface_uri: str
	@param main: the --main argument to pass to 0launch, if any
	@type main: str | None
	@param command: the --command argument to pass to 0launch, if any
	@type command: str | None"""
	assert "'" not in interface_uri
	assert "\\" not in interface_uri
	assert main is None or command is None, "Can't set --main and --command together"

	if main is not None:
		option = "--main '%s' " % main.replace("'", "'\\''")
	elif command is not None:
		option = "--command '%s' " % command.replace("'", "'\\''")
	else:
		option = ""

	stream.write(support.unicode(_template) % (option, interface_uri))

class TestInstall(BaseTest):
	maxDiff = None

	def testHelp(self):
		out, err = self.run_ocaml([])
		assert out.lower().startswith("usage:")
		assert 'add-feed' in out
		assert '--version' in out
		assert err == "Exit status: 1\n", err

		out2, err = self.run_ocaml(['--help'])
		assert err == "Exit status: 1\n", err
		assert out2 == out

		out, err = self.run_ocaml(['--version'])
		assert 'Thomas Leonard' in out
		assert not err, err

		out, err = self.run_ocaml(['foobar'])
		assert 'Unknown 0install sub-command' in err, err

	def testRun(self):
		out, err = self.run_ocaml(['run'])
		assert out.lower().startswith("usage:")
		assert 'URI' in out, out


		out, err = self.run_ocaml(['run', '--dry-run', 'runnable/Runnable.xml', '--help'])
		assert not err, err
		assert 'arg-for-runner' in out, out
		assert '--help' in out, out

	def check_man(self, args, expected):
		out, err = self.run_ocaml(['--dry-run', 'man'] + args)
		assert '[dry-run] man' in out, (out, err)
		args = out[len('[dry-run] man '):]

		man_args = tuple(['man'] + shlex.split(args))
		if len(man_args) == 2:
			arg = man_args[1]
			if '/tests/' in arg:
				arg = 'tests/' + man_args[1].rsplit('/tests/', 1)[1]
			self.assertEqual(expected, arg)
		else:
			self.assertEqual(expected, man_args)

	def testUpdateAlias(self):
		local_feed = os.path.join(mydir, 'Local.xml')
		launcher_script = os.path.join(self.config_home, 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			write_script(stream, local_feed, None)

		out, err = self.run_ocaml(['update', 'my-test-alias'])
		assert err.startswith("Bad interface name 'my-test-alias'.\n(hint: try 'alias:my-test-alias' instead)\n"), err
		self.assertEqual("", out)

	def testMan(self):
		out, err = self.run_ocaml(['man', '--help'])
		assert out.lower().startswith("usage:")

		# Wrong number of args: pass-through
		self.check_man(['git', 'config'], ('man', 'git', 'config'))
		self.check_man([], ('man',))

		local_feed = os.path.realpath(os.path.join(mydir, 'Local.xml'))
		launcher_script = os.path.join(self.config_home, 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			write_script(stream, local_feed, None)
		self.check_man(['my-test-alias'], 'tests/test-echo.1')

		self.check_man(['__i_dont_exist'], '__i_dont_exist')
		self.check_man(['ls'], 'ls')

		# No man-page
		binary_feed = os.path.realpath(os.path.join(mydir, 'Command.xml'))
		launcher_script = os.path.join(self.config_home, 'my-binary-alias')
		with open(launcher_script, 'w') as stream:
			write_script(stream, binary_feed, None)

		out, err = self.run_ocaml(['man', 'my-binary-alias'])
		assert "Exit status: 1" in err, err
		assert "No matching manpage was found for 'my-binary-alias'" in out, out

		with open(os.path.join(self.config_home, 'bad-unicode'), 'wb') as stream:
			stream.write(bytes([198, 65]))
		self.check_man(['bad-unicode'], 'bad-unicode')

	def testAlias(self):
		local_feed = 'Local.xml'
		alias_path = os.path.join(mydir, '..', '0alias')
		child = subprocess.Popen([alias_path, 'local-app', local_feed], stdout = subprocess.PIPE, stderr = subprocess.PIPE, universal_newlines = True)
		out, err = child.communicate()
		assert 'ERROR: "0alias" has been removed; use "0install add" instead' in err, err
		assert not out, out

if __name__ == '__main__':
	unittest.main()
