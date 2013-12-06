"""
Integrates download callbacks with an external mainloop.
While things are being downloaded, Zero Install returns control to your program.
Your mainloop is responsible for monitoring the state of the downloads and notifying
Zero Install when they are complete.

To do this, you supply a L{Handler} to the L{policy}.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import logger

from zeroinstall.support import tasks

class Handler(object):
	"""
	A Handler is used to interact with the user (e.g. to confirm keys, display download progress, etc).

	@ivar monitored_downloads: set of downloads in progress
	@type monitored_downloads: {L{download.Download}}
	@ivar n_completed_downloads: number of downloads which have finished for GUIs, etc (can be reset as desired).
	@type n_completed_downloads: int
	@ivar total_bytes_downloaded: informational counter for GUIs, etc (can be reset as desired). Updated when download finishes.
	@type total_bytes_downloaded: int
	@ivar dry_run: don't write or execute any files, just print notes about what we would have done to stdout
	@type dry_run: bool
	"""

	__slots__ = ['monitored_downloads', 'dry_run', 'total_bytes_downloaded', 'n_completed_downloads']

	def __init__(self, mainloop = None, dry_run = False):
		"""@type dry_run: bool"""
		self.monitored_downloads = set()
		self.dry_run = dry_run
		self.n_completed_downloads = 0
		self.total_bytes_downloaded = 0

	def monitor_download(self, dl):
		"""Called when a new L{download} is started.
		This is mainly used by the GUI to display the progress bar.
		@type dl: L{zeroinstall.injector.download.Download}"""
		self.monitored_downloads.add(dl)
		self.downloads_changed()

		@tasks.async
		def download_done_stats():
			yield dl.downloaded
			# NB: we don't check for exceptions here; someone else should be doing that
			try:
				self.n_completed_downloads += 1
				self.total_bytes_downloaded += dl.get_bytes_downloaded_so_far()
				self.monitored_downloads.remove(dl)
				self.downloads_changed()
			except Exception as ex:
				logger.warning("%s", str(exception) or type(exception), exc_info = True)
		download_done_stats()

	def downloads_changed(self):
		"""This is just for the GUI to override to update its display."""
		pass
