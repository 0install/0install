"""
Handles URL downloads.

This is the low-level interface for downloading interfaces, implementations, icons, etc.

@see: L{fetch} higher-level API for downloads that uses this module
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import tempfile, os

from zeroinstall import SafeException
from zeroinstall.support import tasks
from zeroinstall import _, logger

download_starting = "starting"	# Waiting for UI to start it (no longer used)
download_fetching = "fetching"	# In progress
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

RESULT_OK = 0
RESULT_FAILED = 1
RESULT_NOT_MODIFIED = 2
RESULT_REDIRECT = 3

class DownloadError(SafeException):
	"""Download process failed."""
	pass

class DownloadAborted(DownloadError):
	"""Download aborted because of a call to L{Download.abort}"""
	def __init__(self, message = None):
		SafeException.__init__(self, message or _("Download aborted at user's request"))

class Download(object):
	"""A download of a single resource to a temporary file.
	@ivar url: the URL of the resource being fetched
	@type url: str
	@ivar tempfile: the file storing the downloaded data
	@type tempfile: file
	@ivar status: the status of the download
	@type status: (download_fetching | download_failed | download_complete)
	@ivar expected_size: the expected final size of the file
	@type expected_size: int | None
	@ivar downloaded: triggered when the download ends (on success or failure)
	@type downloaded: L{tasks.Blocker}
	@ivar hint: hint passed by and for caller
	@type hint: object
	@ivar aborted_by_user: whether anyone has called L{abort}
	@type aborted_by_user: bool
	@ivar unmodified: whether the resource was not modified since the modification_time given at construction
	@type unmodified: bool
	@ivar timeout: a Blocker which will be triggered if the download is taking a long time
	@type timeout: Blocker | None
	@ivar mirror: an alternative URL to try if this download fails
	@type mirror: str | None
	"""
	__slots__ = ['url', 'tempfile', 'status', 'expected_size', 'downloaded',
		     'hint', '_final_total_size', 'aborted_by_user', 'mirror',
		     'modification_time', 'unmodified', '_aborted', 'timeout']

	def __init__(self, url, hint = None, modification_time = None, expected_size = None, auto_delete = True):
		"""Create a new download object.
		@param url: the resource to download
		@type url: str
		@param hint: object with which this download is associated (an optional hint for the GUI)
		@param modification_time: string with HTTP date that indicates last modification time. The resource will not be downloaded if it was not modified since that date.
		@type modification_time: str | None
		@type auto_delete: bool
		@postcondition: L{status} == L{download_fetching}."""
		assert auto_delete in (True, False)	# XXX
		self.url = url
		self.hint = hint
		self.aborted_by_user = False		# replace with _aborted?
		self.modification_time = modification_time
		self.unmodified = False

		self.tempfile = None		# Stream for result
		self.downloaded = None
		self.mirror = None

		self.expected_size = expected_size	# Final size (excluding skipped bytes)
		self._final_total_size = None	# Set when download is finished
	
		self.status = download_fetching
		if auto_delete:
			self.tempfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-', mode = 'w+b')
		else:
			self.tempfile = tempfile.NamedTemporaryFile(prefix = 'injector-dl-data-', mode = 'w+b', delete = False)

		self._aborted = tasks.Blocker("abort " + url)

		self.timeout = None

	def _finish(self, status):
		"""@type status: int"""
		assert self.status is download_fetching
		assert self.tempfile is not None
		assert not self.aborted_by_user

		if status == RESULT_NOT_MODIFIED:
			logger.debug("%s not modified", self.url)
			self.tempfile = None
			self.unmodified = True
			self.status = download_complete
			self._final_total_size = 0
			return

		self._final_total_size = self.get_bytes_downloaded_so_far()

		self.tempfile = None

		try:
			assert status == RESULT_OK

			# Check that the download has the correct size, if we know what it should be.
			if self.expected_size is not None:
				if self._final_total_size != self.expected_size:
					raise SafeException(_('Downloaded archive has incorrect size.\n'
							'URL: %(url)s\n'
							'Expected: %(expected_size)d bytes\n'
							'Received: %(size)d bytes') % {'url': self.url, 'expected_size': self.expected_size, 'size': self._final_total_size})
		except:
			self.status = download_failed
			raise
		else:
			self.status = download_complete
	
	def abort(self):
		"""Signal the current download to stop.
		@postcondition: L{aborted_by_user}"""
		self.status = download_failed

		if self.tempfile is not None:
			logger.info(_("Aborting download of %s"), self.url)
			# TODO: we currently just close the output file; the thread will end when it tries to
			# write to it. We should try harder to stop the thread immediately (e.g. by closing its
			# socket when known), although we can never cover all cases (e.g. a stuck DNS lookup).
			# In any case, we don't wait for the child to exit before notifying tasks that are waiting
			# on us.
			self.aborted_by_user = True
			self.tempfile.close()
			if hasattr(self.tempfile, 'delete') and not self.tempfile.delete:
				os.remove(self.tempfile.name)
			self.tempfile = None
			self._aborted.trigger()

	def get_current_fraction(self):
		"""Returns the current fraction of this download that has been fetched (from 0 to 1),
		or None if the total size isn't known. Note that the timeout does not stop the download;
		we just use it as a signal to try a mirror in parallel.
		@return: fraction downloaded
		@rtype: int | None"""
		if self.tempfile is None:
			return 1
		if self.expected_size is None:
			return None		# Unknown
		current_size = self.get_bytes_downloaded_so_far()
		return float(current_size) / self.expected_size
	
	def get_bytes_downloaded_so_far(self):
		"""Get the download progress. Will be zero if the download has not yet started.
		@rtype: int"""
		if self.status is download_fetching:
			if self.tempfile.closed:
				return 1
			else:
				return os.fstat(self.tempfile.fileno()).st_size
		else:
			return self._final_total_size or 0

	def get_next_mirror_url(self):
		"""Return an alternative download URL to try, or None if we're out of options.
		@rtype: str"""
		mirror = self.mirror
		self.mirror = None
		return mirror
	
	def __str__(self):
		return _("<Download from %s>") % self.url
