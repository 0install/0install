#!/usr/bin/env python
from basetest import BaseTest
import os, sys, subprocess
import unittest
from StringIO import StringIO

sys.path.insert(0, '..')

from zeroinstall.injector import policy, run
from zeroinstall import SafeException

mydir = os.path.abspath(os.path.dirname(__file__))
local_0launch = os.path.join(os.path.dirname(mydir), '0launch')
runnable = os.path.join(mydir, 'runnable', 'Runnable.xml')
recursive_runner = os.path.join(mydir, 'runnable', 'RecursiveRunner.xml')
command_feed = os.path.join(mydir, 'Command.xml')

class TestRun(BaseTest):
	def testRunnable(self):
		child = subprocess.Popen([local_0launch, '--', runnable, 'user-arg'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Runner: script=A test script: args=command-arg -- user-arg' in stdout, stdout

	def testCommandBindings(self):
		p = policy.Policy(command_feed, config = self.config)
		self.config.handler.wait_for_blocker(p.solve_with_downloads())
		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], main = 'runner', dry_run = True, stores = self.config.stores)
		finally:
			sys.stdout = old_stdout
		assert 'local' in os.environ['LOCAL'], os.environ['LOCAL']

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
	
if __name__ == '__main__':
	unittest.main()
