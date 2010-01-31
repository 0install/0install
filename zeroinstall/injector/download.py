"""
Handles URL downloads.

This is the low-level interface for downloading interfaces, implementations, icons, etc.

@see: L{fetch} higher-level API for downloads that uses this module
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import tempfile, os, sys, subprocess

if __name__ == '__main__':
	sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from zeroinstall import SafeException
from zeroinstall.support import tasks
from logging import info, debug
from zeroinstall import _

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

RESULT_OK = 0
RESULT_FAILED = 1
RESULT_NOT_MODIFIED = 2

class DownloadError(SafeException):
	"""Download process failed."""
	pass

class DownloadAborted(DownloadError):
	"""Download aborted because of a call to L{Download.abort}"""
	def __init__(self, message):
		SafeException.__init__(self, message or _("Download aborted at user's request"))

class Download(object):
	"""A download of a single resource to a temporary file.
	@ivar url: the URL of the resource being fetched
	@type url: str
	@ivar tempfile: the file storing the downloaded data
	@type tempfile: file
	@ivar status: the status of the download
	@type status: (download_starting | download_fetching | download_failed | download_complete)
	@ivar errors: data received from the child's stderr
	@type errors: str
	@ivar expected_size: the expected final size of the file
	@type expected_size: int | None
	@ivar downloaded: triggered when the download ends (on success or failure)
	@type downloaded: L{tasks.Blocker}
	@ivar hint: hint passed by and for caller
	@type hint: object
	@ivar child: the child process
	@type child: subprocess.Popen
	@ivar aborted_by_user: whether anyone has called L{abort}
	@type aborted_by_user: bool
	@ivar unmodified: whether the resource was not modified since the modification_time given at construction
	@type unmodified: bool
	"""
	__slots__ = ['url', 'tempfile', 'status', 'errors', 'expected_size', 'downloaded',
		     'hint', 'child', '_final_total_size', 'aborted_by_user',
		     'modification_time', 'unmodified']

	def __init__(self, url, hint = None, modification_time = None):
		"""Create a new download object.
		@param url: the resource to download
		@param hint: object with which this download is associated (an optional hint for the GUI)
		@param modification_time: string with HTTP date that indicates last modification time.
		  The resource will not be downloaded if it was not modified since that date.
		@postcondition: L{status} == L{download_starting}."""
		self.url = url
		self.status = download_starting
		self.hint = hint
		self.aborted_by_user = False
		self.modification_time = modification_time
		self.unmodified = False

		self.tempfile = None		# Stream for result
		self.errors = None
		self.downloaded = None

		self.expected_size = None	# Final size (excluding skipped bytes)
		self._final_total_size = None	# Set when download is finished

		self.child = None
	
	def start(self):
		"""Create a temporary file and begin the download.
		@precondition: L{status} == L{download_starting}"""
		assert self.status == download_starting
		assert self.downloaded is None

		self.tempfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-')

		task = tasks.Task(self._do_download(), "download " + self.url)
		self.downloaded = task.finished

	def _do_download(self):
		"""Will trigger L{downloaded} when done (on success or failure)."""
		self.errors = ''

		# Can't use fork here, because Windows doesn't have it
		assert self.child is None, self.child
		child_args = [sys.executable, '-u', __file__, self.url]
		if self.modification_time: child_args.append(self.modification_time)
		self.child = subprocess.Popen(child_args, stderr = subprocess.PIPE, stdout = self.tempfile)

		self.status = download_fetching

		# Wait for child to exit, collecting error output as we go

		while True:
			yield tasks.InputBlocker(self.child.stderr, "read data from " + self.url)

			data = os.read(self.child.stderr.fileno(), 100)
			if not data:
				break
			self.errors += data

		# Download is complete...

		assert self.status is download_fetching
		assert self.tempfile is not None
		assert self.child is not None

		status = self.child.wait()
		self.child = None

		errors = self.errors
		self.errors = None

		if status == RESULT_NOT_MODIFIED:
			debug("%s not modified", self.url)
			self.tempfile = None
			self.unmodified = True
			self.status = download_complete
			self._final_total_size = 0
			self.downloaded.trigger()
			return

		if status and not self.aborted_by_user and not errors:
			errors = _('Download process exited with error status '
					   'code %s') % hex(status)

		self._final_total_size = self.get_bytes_downloaded_so_far()

		stream = self.tempfile
		self.tempfile = None

		try:
			if self.aborted_by_user:
				raise DownloadAborted(errors)

			if errors:
				raise DownloadError(errors.strip())

			# Check that the download has the correct size, if we know what it should be.
			if self.expected_size is not None:
				size = os.fstat(stream.fileno()).st_size
				if size != self.expected_size:
					raise SafeException(_('Downloaded archive has incorrect size.\n'
							'URL: %(url)s\n'
							'Expected: %(expected_size)d bytes\n'
							'Received: %(size)d bytes') % {'url': self.url, 'expected_size': self.expected_size, 'size': size})
		except:
			self.status = download_failed
			_unused, ex, tb = sys.exc_info()
			self.downloaded.trigger(exception = (ex, tb))
		else:
			self.status = download_complete
			self.downloaded.trigger()
	
	def abort(self):
		"""Signal the current download to stop.
		@postcondition: L{aborted_by_user}"""
		if self.child is not None:
			info(_("Killing download process %s"), self.child.pid)
			import signal
			os.kill(self.child.pid, signal.SIGTERM)
			self.aborted_by_user = True
		else:
			self.status = download_failed

	def get_current_fraction(self):
		"""Returns the current fraction of this download that has been fetched (from 0 to 1),
		or None if the total size isn't known.
		@return: fraction downloaded
		@rtype: int | None"""
		if self.status is download_starting:
			return 0
		if self.tempfile is None:
			return 1
		if self.expected_size is None:
			return None		# Unknown
		current_size = self.get_bytes_downloaded_so_far()
		return float(current_size) / self.expected_size
	
	def get_bytes_downloaded_so_far(self):
		"""Get the download progress. Will be zero if the download has not yet started.
		@rtype: int"""
		if self.status is download_starting:
			return 0
		elif self.status is download_fetching:
			return os.fstat(self.tempfile.fileno()).st_size
		else:
			return self._final_total_size
	
	def __str__(self):
		return _("<Download from %s>") % self.url

if __name__ == '__main__':
	def _download_as_child(url, if_modified_since):
		from httplib import HTTPException
		from urllib2 import urlopen, Request, HTTPError, URLError
		try:
			#print "Child downloading", url
			if url.startswith('/'):
				if not os.path.isfile(url):
					print >>sys.stderr, "File '%s' does not " \
						"exist!" % url
					return
				src = file(url)
			elif url.startswith('http:') or url.startswith('https:') or url.startswith('ftp:'):
				req = Request(url)
				if url.startswith('http:') and if_modified_since:
					req.add_header('If-Modified-Since', if_modified_since)
				src = urlopen(req)
			else:
				raise Exception(_('Unsupported URL protocol in: %s') % url)

			try:
				sock = src.fp._sock
			except AttributeError:
				sock = src.fp.fp._sock	# Python 2.5 on FreeBSD
			while True:
				data = sock.recv(256)
				if not data: break
				os.write(1, data)

			sys.exit(RESULT_OK)
		except (HTTPError, URLError, HTTPException), ex:
			if isinstance(ex, HTTPError) and ex.code == 304: # Not modified
				sys.exit(RESULT_NOT_MODIFIED)
			print >>sys.stderr, "Error downloading '" + url + "': " + (str(ex) or str(ex.__class__.__name__))
			sys.exit(RESULT_FAILED)
	assert (len(sys.argv) == 2) or (len(sys.argv) == 3), "Usage: download URL [If-Modified-Since-Date], not %s" % sys.argv
	if len(sys.argv) >= 3:
		if_modified_since_date = sys.argv[2]
	else:
		if_modified_since_date = None
	_download_as_child(sys.argv[1], if_modified_since_date)
