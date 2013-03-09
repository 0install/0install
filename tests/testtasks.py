#!/usr/bin/env python
from basetest import BaseTest
import unittest
import os, sys

sys.path.insert(0, '..')
from zeroinstall.support import tasks

# Most of tasks.py is heavily tested by the rest of the code, but some bits aren't.
class TestTasks(BaseTest):
	def testInputBlocker(self):
		r, w = os.pipe()
		b = tasks.InputBlocker(r, "waiting for input")
		t = tasks.TimeoutBlocker(0.01, "timeout")

		@tasks.async
		def run():
			yield b, t
			assert t.happened
			assert not b.happened

			os.write(w, b"!")

			yield b
			assert b.happened

			os.close(r)
			os.close(w)

		tasks.wait_for_blocker(run())

if __name__ == '__main__':
	unittest.main()
