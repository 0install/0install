#!/usr/bin/env python
import sys
from basetest import BaseTest
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import scheduler
from zeroinstall.support import tasks

real_spawn = scheduler._spawn_thread

class DummyDownload:
	def __init__(self, url, downloads):
		self._aborted = tasks.Blocker("abort " + url)
		self.url = url
		self.downloads = downloads

	def _finish(self, status):
		self.downloads[self.url] = status

class TestSchedular(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

	def tearDown(self):
		BaseTest.tearDown(self)
		scheduler._spawn_thread = real_spawn

	def testQueuing(self):
		#import logging; logging.getLogger().setLevel(logging.DEBUG)

		site = scheduler.Site()

		steps = []

		downloads = {}

		@tasks.async
		def dummy_spawn_thread(step):
			resume = tasks.Blocker('complete ' + step.url)
			downloads[step.url] = resume
			yield resume
			try:
				tasks.check(resume)
			except Exception:
				step.status = "fail"
			else:
				step.status = "ok"

		scheduler._spawn_thread = dummy_spawn_thread
		scheduler.MAX_DOWNLOADS_PER_SITE = 2

		for i in range(4):
			dl = DummyDownload("http://step/" + str(i), downloads)

			s = scheduler.DownloadStep()
			s.url = dl.url
			s.dl = dl
			steps.append(site.download(s))

		@tasks.async
		def collect():
			# Let the first two downloads start
			for x in range(10): yield
			self.assertEqual(2, len(downloads))

			# Let one of them complete
			url, blocker = list(downloads.items())[0]
			blocker.trigger()
			for x in range(10): yield
			self.assertEqual(3, len(downloads))

			# Check it was successful
			self.assertEqual("ok", downloads[url])
			del downloads[url]

			# Let the next one fail
			url, blocker = list(downloads.items())[0]
			blocker.trigger(exception = (Exception("test"), None))
			for x in range(10): yield
			self.assertEqual(3, len(downloads))

			# Check it failed
			self.assertEqual("fail", downloads[url])
			del downloads[url]

			# The last two should both be in progress now.
			# Allow them both to finish.
			blockers = list(downloads.values())
			blockers[0].trigger()
			blockers[1].trigger()
			for x in range(10): yield
			results = list(downloads.values())
			self.assertEqual(["ok", "ok"], results)

		tasks.wait_for_blocker(collect())

if __name__ == '__main__':
	unittest.main()
