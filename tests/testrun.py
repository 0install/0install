#!/usr/bin/env python
from basetest import BaseTest
import os, sys, subprocess
import unittest
from StringIO import StringIO

sys.path.insert(0, '..')

# (testing command support imports zeroinstall.injector._runenv in a sub-process)
os.environ['PYTHONPATH'] = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

from zeroinstall.injector import policy, run, namespaces
from zeroinstall import SafeException

mydir = os.path.abspath(os.path.dirname(__file__))
local_0launch = os.path.join(os.path.dirname(mydir), '0launch')
runnable = os.path.join(mydir, 'runnable', 'Runnable.xml')
runexec = os.path.join(mydir, 'runnable', 'RunExec.xml')
recursive_runner = os.path.join(mydir, 'runnable', 'RecursiveRunner.xml')
command_feed = os.path.join(mydir, 'Command.xml')
package_selections = os.path.join(mydir, 'package-selection.xml')

class TestRun(BaseTest):
	def testRunnable(self):
		child = subprocess.Popen([local_0launch, '--', runnable, 'user-arg'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=command-arg -- user-arg' in stdout, stdout

	def testCommandBindings(self):
		if 'SELF_COMMAND' in os.environ:
			del os.environ['SELF_COMMAND']

		p = policy.Policy(command_feed, config = self.config)
		self.config.handler.wait_for_blocker(p.solve_with_downloads())
		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], main = 'runnable/go.sh', dry_run = True, stores = self.config.stores)
		finally:
			sys.stdout = old_stdout
		assert 'local' in os.environ['LOCAL'], os.environ['LOCAL']
		assert 'SELF_COMMAND' in os.environ

	def testAbsMain(self):
		p = policy.Policy(command_feed, config = self.config)
		self.config.handler.wait_for_blocker(p.solve_with_downloads())

		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], main = '/runnable/runner', dry_run = True, stores = self.config.stores)
		finally:
			sys.stdout = old_stdout

		try:
			old_stdout = sys.stdout
			try:
				sys.stdout = StringIO()
				run.execute_selections(p.solver.selections, [], main = '/runnable/not-there', dry_run = True, stores = self.config.stores)
			finally:
				sys.stdout = old_stdout
		except SafeException as ex:
			assert 'not-there' in unicode(ex)

	def testArgs(self):
		p = policy.Policy(runnable, config = self.config)
		self.config.handler.wait_for_blocker(p.solve_with_downloads())
		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], dry_run = True, stores = self.config.stores)
			out = sys.stdout.getvalue()
		finally:
			sys.stdout = old_stdout
		assert 'runner-arg' in out, out

	def testWrapper(self):
		p = policy.Policy(runnable, config = self.config)
		self.config.handler.wait_for_blocker(p.solve_with_downloads())
		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], wrapper = 'echo', dry_run = True, stores = self.config.stores)
			out = sys.stdout.getvalue()
		finally:
			sys.stdout = old_stdout
		assert '/bin/sh -c echo "$@"' in out, out
		assert 'runner-arg' in out, out
		assert 'script' in out, out

	def testRecursive(self):
		child = subprocess.Popen([local_0launch, '--', recursive_runner, 'user-arg'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=command-arg -- arg-for-runnable recursive-arg -- user-arg' in stdout, stdout

	def testExecutable(self):
		child = subprocess.Popen([local_0launch, '--', runexec, 'user-arg-run'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=foo-arg -- var user-arg-run' in stdout, stdout
		assert 'Runner: script=A test script: args=command-arg -- path user-arg-run' in stdout, stdout

		# Check runenv.py is updated correctly
		from zeroinstall.support import basedir
		runenv = basedir.load_first_cache(namespaces.config_site, namespaces.config_prog, 'runenv.py')
		os.chmod(runenv, 0700)
		with open(runenv, 'wb') as s:
			s.write('#!/\n')

		child = subprocess.Popen([local_0launch, '--', runexec, 'user-arg-run'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=foo-arg -- var user-arg-run' in stdout, stdout
		assert 'Runner: script=A test script: args=command-arg -- path user-arg-run' in stdout, stdout
	
	def testRunPackage(self):
		if 'TEST' in os.environ:
			del os.environ['TEST']
		child = subprocess.Popen([local_0launch, '--wrapper', 'echo $TEST #', '--', package_selections], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert stdout.strip() == 'OK', stdout
	
if __name__ == '__main__':
	unittest.main()
