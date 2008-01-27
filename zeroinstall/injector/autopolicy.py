"""
A simple non-interactive policy.

This module provides a simple policy that will select, download and run a suitable set of
implementations. It is not interactive. This is the policy used when you run B{0launch -c}, and
is also the policy used to run the injector's GUI.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from logging import debug, info

from zeroinstall.support import tasks
from zeroinstall.injector import model, policy, run
from zeroinstall.injector.handler import Handler
from zeroinstall import NeedDownload

class AutoPolicy(policy.Policy):
	__slots__ = ['allow_downloads', 'download_only', 'dry_run']

	def __init__(self, interface_uri, download_only = False, dry_run = False, src = False, handler = None):
		"""@param handler: (new in 0.30) handler to use, or None to create a L{Handler}"""
		policy.Policy.__init__(self, interface_uri, handler or Handler(), src = src)
		self.dry_run = dry_run
		self.allow_downloads = not dry_run
		self.download_only = download_only
		self.dry_run = dry_run

	def download_and_import_feed(self, feed_url, force = False):
		if self.dry_run or not self.allow_downloads:
			raise NeedDownload(feed_url)
		else:
			return policy.Policy.download_and_import_feed(self, feed_url, force)

	def download_archive(self, download_source, force = False):
		if self.dry_run or not self.allow_downloads:
			raise NeedDownload(download_source.url)
		return policy.Policy.download_archive(self, download_source, force = force)

	def execute(self, prog_args, main = None, wrapper = None):
		task = tasks.Task(self.download_impls(), "download_impls")
		self.handler.wait_for_blocker(task.finished)
		if not self.download_only:
			run.execute(self, prog_args, dry_run = self.dry_run, main = main, wrapper = wrapper)
		else:
			info("Downloads done (download-only mode)")
	
	def download_and_execute(self, prog_args, refresh = False, main = None):
		task = tasks.Task(self.solve_with_downloads(refresh), "solve_with_downloads")

		errors = self.handler.wait_for_blocker(task.finished)
		if errors:
			raise model.SafeException("Errors during download: " + '\n'.join(errors))

		if not self.solver.ready:
			raise model.SafeException("Can't find all required implementations:\n" +
				'\n'.join(["- %s -> %s" % (iface, self.solver.selections[iface])
					   for iface  in self.solver.selections]))
		self.execute(prog_args, main = main)
