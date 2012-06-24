#!/usr/bin/env python
from __future__ import with_statement
import unittest
import sys
import os
import tempfile
import shutil
from basetest import BaseTest

sys.path.insert(0, '..')

from zeroinstall import SafeException
from zeroinstall.injector.fetch import StepRunner
from zeroinstall.injector.model import RenameStep

class TestRecipe(BaseTest):
	def setUp(self):
		super(TestRecipe, self).setUp()
		self.basedir = tempfile.mkdtemp()
		self.join = lambda *a: os.path.join(self.basedir, *a)
		os.makedirs(self.join("dir1"))
		os.makedirs(self.join("level1", "level2"))
		with open(self.join("level1", "level2", "level3"), 'w') as f:
			f.write("level3 contents")
		with open(self.join("rootfile"), 'w') as f:
			f.write("rootfile contents")

	def tearDown(self):
		shutil.rmtree(self.basedir)
		super(TestRecipe, self).tearDown()

	def _apply_step(self, step, **k):
		if not 'force' in k: k['force'] = False
		if not 'impl_hint' in k: k['impl_hint'] = None
		cls = StepRunner.class_for(step)
		runner = cls(step, **k)
		# NOTE: runner.prepare() is not performed in these tests,
		# as they test local operations only that require no preparation
		runner.apply(self.basedir)
		
	def _assert_denies_escape(self, step):
		try:
			self._apply_step(step)
			assert False
		except SafeException as e:
			if not 'is not within the base directory' in str(e): raise e

	def testRenameDisallowsEscapingArchiveDirViaSrcSymlink(self):
		os.symlink("/usr/bin", self.join("bin"))
		self._assert_denies_escape(RenameStep(source="bin/gpg", dest="gpg"))

	def testRenameDisallowsEscapingArchiveDirViaDestSymlink(self):
		os.symlink("/tmp", self.join("tmp"))
		self._assert_denies_escape(RenameStep(source="rootfile", dest="tmp/surprise"))

	def testRenameDisallowsEscapingArchiveDirViaSrcRelativePath(self):
		self._assert_denies_escape(RenameStep(source="../somefile", dest="somefile"))

	def testRenameDisallowsEscapingArchiveDirViaDestRelativePath(self):
		self._assert_denies_escape(RenameStep(source="rootfile", dest="../somefile"))

	def testRenameDisallowsEscapingArchiveDirViaSrcAbsolutePath(self):
		self._assert_denies_escape(RenameStep(source="/usr/bin/gpg", dest="gpg"))

	def testRenameDisallowsEscapingArchiveDirViaDestAbsolutePath(self):
		self._assert_denies_escape(RenameStep(source="rootfile", dest="/tmp/rootfile"))

if __name__ == '__main__':
	unittest.main()
