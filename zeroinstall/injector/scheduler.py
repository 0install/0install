"""
Manage pools of connections so that we can limit the number of requests per site and reuse
connections.
@since: 1.6
"""

# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import urlparse
from collections import defaultdict
import threading, gobject

from zeroinstall.support import tasks
from zeroinstall.injector import download

default_port = {
	'http': 80,
	'https': 443,
}

class DownloadStep:
	url = None
	status = None
	redirect = None

class DownloadScheduler:
	"""Assigns (and re-assigns on redirect) Downloads to Sites, allowing per-site limits and connection pooling.
	@since: 1.6"""
	def __init__(self):
		self._sites = defaultdict(lambda: Site())	# (scheme://host:port) -> Site
	
	@tasks.async
	def download(self, dl):
		# (changed if we get redirected)
		current_url = dl.url

		redirections_remaining = 10

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
			blocker = self._sites[site_key].download(step)
			yield blocker
			tasks.check(blocker)
			
			if not step.redirect:
				break

			current_url = step.redirect

			if redirections_remaining == 0:
				raise download.DownloadError("Too many redirections {url} -> {current}".format(
						url = dl.url,
						current = current_url))
			redirections_remaining -= 1
			# (else go around the loop again)

class Site:
	"""Represents a service accepting download requests. All requests with the same scheme, host and port are
	handled by the same Site object, allowing it to do connection pooling and queuing, although the current
	implementation doesn't do either."""
	@tasks.async
	def download(self, step):
		from ._download_child import download_in_thread

		thread_blocker = tasks.Blocker("wait for thread " + step.url)
		def notify_done(status, ex = None, redirect = None):
			step.status = status
			step.redirect = redirect
			def wake_up_main():
				thread_blocker.trigger(ex)
				return False
			gobject.idle_add(wake_up_main)
		child = threading.Thread(target = lambda: download_in_thread(step.url, step.dl.tempfile, step.dl.modification_time, notify_done))
		child.daemon = True
		child.start()

		# Wait for child to complete download.
		yield thread_blocker, step.dl._aborted

		if step.dl._aborted.happened:
			# Don't wait for child to finish (might be stuck doing IO)
			raise download.DownloadAborted()

		# Download is complete...
		child.join()

		tasks.check(thread_blocker)

		if step.status == download.RESULT_REDIRECT:
			assert step.redirect
			return				# DownloadScheduler will handle it

		assert not step.redirect, step.redirect

		step.dl._finish(step.status)
