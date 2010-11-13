#!/usr/bin/env python
from basetest import BaseTest
import os, sys, subprocess
import unittest
from StringIO import StringIO

sys.path.insert(0, '..')

from zeroinstall.injector import policy, run, handler, model

mydir = os.path.abspath(os.path.dirname(__file__))
local_0launch = os.path.join(os.path.dirname(mydir), '0launch')
runnable = os.path.join(mydir, 'runnable', 'Runnable.xml')

class TestRun(BaseTest):
	def testRunnable(self):
		child = subprocess.Popen([local_0launch, '--', runnable, 'user-arg'], stdout = subprocess.PIPE)
		stdout, _ = child.communicate()
		assert 'Args: command-arg -- user-arg' in stdout, stdout

	def testCommandBindings(self):
		command_feed = os.path.join(mydir, 'Command.xml')
		h = handler.Handler()
		p = policy.Policy(command_feed, handler = h)
		h.wait_for_blocker(p.solve_with_downloads())
		old_stdout = sys.stdout
		try:
			sys.stdout = StringIO()
			run.execute_selections(p.solver.selections, [], main = '.', dry_run = True)
		finally:
			sys.stdout = old_stdout
		assert 'local' in os.environ['LOCAL'], os.environ['LOCAL']
	
if __name__ == '__main__':
	unittest.main()
