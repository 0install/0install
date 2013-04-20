"""
Manage pools of connections so that we can limit the number of requests per site and reuse
connections.
@since: 1.6
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys

if sys.version_info[0] > 2:
	from urllib import parse as urlparse	# Python 3
else:
	import urlparse

from collections import defaultdict
import threading

from zeroinstall import logger
from zeroinstall.support import tasks
from zeroinstall.injector import download

default_port = {
	'http': 80,
	'https': 443,
}

class DownloadStep(object):
	url = None
	status = None
	redirect = None

class DownloadScheduler(object):
	"""Assigns (and re-assigns on redirect) Downloads to Sites, allowing per-site limits and connection pooling.
	@since: 1.6"""
	def __init__(self):
		self._sites = defaultdict(lambda: Site())	# (scheme://host:port) -> Site
	
	@tasks.async
	def download(self, dl, timeout = None):
		"""@type dl: L{zeroinstall.injector.download.Download}"""

		# (changed if we get redirected)
		current_url = dl.url

		redirections_remaining = 10

		original_exception = None

		# Assign the Download to a Site based on its scheme, host and port. If the result is a redirect,
		# reassign it to the appropriate new site. Note that proxy handling happens later; we want to group
		# and limit by the target site, not treat everything as going to a single site (the proxy).
		while True:
			location_parts = urlparse.urlparse(current_url)

			site_key = (location_parts.scheme,
				    location_parts.hostname,
				    location_parts.port or default_port.get(location_parts.scheme, None))

			step = DownloadStep()
			step.dl = dl
			step.url = current_url
			blocker = self._sites[site_key].download(step, timeout)
			yield blocker

			try:
				tasks.check(blocker)
			except download.DownloadError as ex:
				if original_exception is None:
					original_exception = ex
				else:
					logger.warning("%s (while trying mirror)", ex)
				mirror_url = step.dl.get_next_mirror_url()
				if mirror_url is None:
					raise original_exception

				# Try the mirror.
				# There are actually two places where we try to use the mirror: this one
				# looks to see if we have an exact copy of same file somewhere else. If this
				# fails, Fetcher will also look for a different archive that would generate
				# the required implementation.
				logger.warning("%s: trying archive mirror at %s", ex, mirror_url)
				step.redirect = mirror_url
				redirections_remaining = 10

			if not step.redirect:
				break

			current_url = step.redirect

			if redirections_remaining == 0:
				raise download.DownloadError("Too many redirections {url} -> {current}".format(
						url = dl.url,
						current = current_url))
			redirections_remaining -= 1
			# (else go around the loop again)

MAX_DOWNLOADS_PER_SITE = 5

def _spawn_thread(step):
	"""@type step: L{DownloadStep}
	@rtype: L{zeroinstall.support.tasks.Blocker}"""
	from ._download_child import download_in_thread

	thread_blocker = tasks.Blocker("wait for thread " + step.url)
	def notify_done(status, ex = None, redirect = None):
		step.status = status
		step.redirect = redirect
		def wake_up_main():
			child.join()
			thread_blocker.trigger(ex)
			return False
		tasks.get_loop().call_soon_threadsafe(wake_up_main)
	child = threading.Thread(target = lambda: download_in_thread(step.url, step.dl.tempfile, step.dl.modification_time, notify_done))
	child.daemon = True
	child.start()

	return thread_blocker

class Site(object):
	"""Represents a service accepting download requests. All requests with the same scheme, host and port are
	handled by the same Site object, allowing it to do connection pooling and queuing, although the current
	implementation doesn't do either."""
	def __init__(self):
		self.queue = []
		self.active = 0

	@tasks.async
	def download(self, step, timeout = None):
		"""
		Queue up this download. If it takes too long, trigger step.dl.timeout (if any), but
		only count time spent actually downloading, not time spent queuing.
		@type step: L{DownloadStep}"""
		if self.active == MAX_DOWNLOADS_PER_SITE:
			# Too busy to start a new download now. Queue this one and wait.
			ticket = tasks.Blocker('queued download for ' + step.url)
			self.queue.append(ticket)
			yield ticket, step.dl._aborted
			if step.dl._aborted.happened:
				raise download.DownloadAborted()

		in_progress = [True]
		if timeout is not None:
			def timeout_cb():
				if in_progress:
					step.dl.timeout.trigger()
			tasks.get_loop().call_later(timeout, timeout_cb)

		# Start a new thread for the download
		thread_blocker = _spawn_thread(step)

		self.active += 1

		# Wait for thread to complete download.
		yield thread_blocker, step.dl._aborted

		del in_progress[0]

		self.active -= 1
		if self.active < MAX_DOWNLOADS_PER_SITE:
			self.process_next()		# Start next queued download, if any

		if step.dl._aborted.happened:
			# Don't wait for child to finish (might be stuck doing IO)
			raise download.DownloadAborted()

		tasks.check(thread_blocker)

		if step.status == download.RESULT_REDIRECT:
			assert step.redirect
			return				# DownloadScheduler will handle it

		assert not step.redirect, step.redirect

		step.dl._finish(step.status)

	def process_next(self):
		assert self.active < MAX_DOWNLOADS_PER_SITE

		if self.queue:
			nxt = self.queue.pop()
			nxt.trigger()
