#!/usr/bin/env python
from basetest import BaseTest
import os, sys, subprocess
import unittest

sys.path.insert(0, '..')

# (testing command support imports zeroinstall.injector._runenv in a sub-process)
os.environ['PYTHONPATH'] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

from zeroinstall import SafeException

mydir = os.path.abspath(os.path.dirname(__file__))
local_0launch = os.path.join(mydir, '..', 'build', 'ocaml', '0launch')
arglist = os.path.join(mydir, 'runnable', 'ArgList.xml')
runnable = os.path.join(mydir, 'runnable', 'Runnable.xml')
runexec = os.path.join(mydir, 'runnable', 'RunExec.xml')
recursive_runner = os.path.join(mydir, 'runnable', 'RecursiveRunner.xml')
command_feed = os.path.join(mydir, 'Command.xml')
package_selections = os.path.join(mydir, 'package-selection.xml')

class TestRun(BaseTest):
	def testRunnable(self):
		child = subprocess.Popen([local_0launch, '--', runnable, 'user-arg'], stdout = subprocess.PIPE, universal_newlines = True)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=command-arg -- user-arg' in stdout, stdout

	def testCommandBindings(self):
		if 'SELF_COMMAND' in os.environ:
			del os.environ['SELF_COMMAND']

		out, err = self.run_ocaml(['run', '--main=runnable/go.sh', '-wenv #', command_feed])
		assert not err, err
		assert 'LOCAL=' in out, out
		assert 'SELF_COMMAND=' in out, out

	def testAbsMain(self):
		out, err = self.run_ocaml(['run', '--dry-run', '--main=runnable/runner', command_feed])
		assert '[dry-run] would execute: ././runnable/runner' in out, out
		assert not err, err

		out, err = self.run_ocaml(['run', '--main=runnable/not-there', command_feed])
		assert not out, out
		assert 'not-there' in err, err

	def testBadMain(self):
		out, err = self.run_ocaml(['run', '--dry-run', '--command=', command_feed])
		assert "Exit status: 1" in err, err
		assert "Can't run: no command specified!" in err, err

		out, err = self.run_ocaml(['run', '--dry-run', '--command=', '--main=relpath', command_feed])
		assert "Exit status: 1" in err, err
		assert "Can't use a relative replacement main (relpath) when there is no original one!" in err, err

	def testArgs(self):
		out, err = self.run_ocaml(['run', '--dry-run', runnable])
		assert not err, err
		assert 'runner-arg' in out, out

	def testArgList(self):
		out, err = self.run_ocaml(['run', '--dry-run', arglist])
		assert not err, err
		assert 'arg-for-runner -X ra1 -X ra2' in out, out
		assert 'command-arg ca1 ca2' in out, out

	def testWrapper(self):
		out, err = self.run_ocaml(['run', '-wecho', '--dry-run', runnable])
		assert not err, err
		assert '/bin/sh -c echo "$@"' in out, out
		assert 'runner-arg' in out, out
		assert 'script' in out, out

	def testRecursive(self):
		child = subprocess.Popen([local_0launch, '--', recursive_runner, 'user-arg'], stdout = subprocess.PIPE, universal_newlines = True)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=command-arg -- arg-for-runnable recursive-arg -- user-arg' in stdout, stdout

	def testExecutable(self):
		child = subprocess.Popen([local_0launch, '--', runexec, 'user-arg-run'], stdout = subprocess.PIPE, universal_newlines = True)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=foo-arg -- var user-arg-run' in stdout, stdout
		assert 'Runner: script=A test script: args=command-arg -- path user-arg-run' in stdout, stdout

	def testRunPackage(self):
		if 'TEST' in os.environ:
			del os.environ['TEST']
		child = subprocess.Popen([local_0launch, '--wrapper', 'echo $TEST #', '--', package_selections], stdout = subprocess.PIPE, universal_newlines = True)
		stdout, _ = child.communicate()
		assert stdout.strip() == 'OK', stdout
	
if __name__ == '__main__':
	unittest.main()
