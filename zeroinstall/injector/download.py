"""
Handles URL downloads.

This is the low-level interface for downloading interfaces, implementations, icons, etc.

@see: L{policy.Policy.begin_iface_download}
@see: L{policy.Policy.begin_archive_download}
@see: L{policy.Policy.begin_icon_download}
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import tempfile, os, sys
from zeroinstall import SafeException
from zeroinstall.support import tasks
import traceback
from logging import info

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

class DownloadError(SafeException):
	pass

class Download(object):
	__slots__ = ['url', 'tempfile', 'status', 'errors', 'expected_size', 'downloaded',
		     'expected_size', 'child_pid', 'child_stderr', '_final_total_size']

	def __init__(self, url):
		"Initial status is starting."
		self.url = url
		self.status = download_starting

		self.tempfile = None		# Stream for result
		self.errors = None
		self.downloaded = None

		self.expected_size = None	# Final size (excluding skipped bytes)
		self._final_total_size = None	# Set when download is finished

		self.child_pid = None
		self.child_stderr = None
	
	def start(self):
		assert self.status == download_starting
		assert self.downloaded is None

		self.tempfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-')

		task = tasks.Task(self._do_download(), "download " + self.url)
		self.downloaded = task.finished

	def _do_download(self):
		"""Will trigger L{downloaded} when done (on success or failure)."""
		error_r, error_w = os.pipe()
		self.errors = ''

		self.child_pid = os.fork()
		if self.child_pid == 0:
			# We are the child
			try:
				os.close(error_r)
				os.dup2(error_w, 2)
				os.close(error_w)
				self.download_as_child()
			finally:
				os._exit(1)

		# We are the parent
		os.close(error_w)
		self.status = download_fetching

		#stream =  os.fdopen(error_r, 'r')

		# Wait for child to exit, collecting error output as we go

		while True:
			yield tasks.InputBlocker(error_r, "read data from " + self.url)

			data = os.read(error_r, 100)
			if not data:
				break
			self.errors += data

		# Download is complete...

		assert self.status is download_fetching
		assert self.tempfile is not None
		assert self.child_pid is not None

		pid, status = os.waitpid(self.child_pid, 0)
		assert pid == self.child_pid
		self.child_pid = None

		errors = self.errors
		self.errors = None

		if status and not errors:
			errors = 'Download process exited with error status ' \
				 'code ' + hex(status)

		self._final_total_size = self.get_bytes_downloaded_so_far()

		stream = self.tempfile
		self.tempfile = None

		try:
			if errors:
				raise DownloadError(errors)

			# Check that the download has the correct size, if we know what it should be.
			if self.expected_size is not None:
				size = os.fstat(stream.fileno()).st_size
				if size != self.expected_size:
					raise SafeException('Downloaded archive has incorrect size.\n'
							'URL: %s\n'
							'Expected: %d bytes\n'
							'Received: %d bytes' % (self.url, self.expected_size, size))
		except:
			self.status = download_failed
			_, ex, tb = sys.exc_info()
			self.downloaded.trigger(exception = (ex, tb))
		else:
			self.status = download_complete
			self.downloaded.trigger()
	
	def download_as_child(self):
		try:
			from urllib2 import urlopen, HTTPError, URLError
			import shutil
			#print "Child downloading", self.url
			if self.url.startswith('/'):
				if not os.path.isfile(self.url):
					print >>sys.stderr, "File '%s' does not " \
						"exist!" % self.url
					return
				src = file(self.url)
			elif self.url.startswith('http:') or self.url.startswith('ftp:'):
				src = urlopen(self.url)
			else:
				raise Exception('Unsupported URL protocol in: ' + self.url)

			shutil.copyfileobj(src, self.tempfile)
			self.tempfile.flush()
			
			os._exit(0)
		except (HTTPError, URLError), ex:
			print >>sys.stderr, "Error downloading '" + self.url + "': " + str(ex)
		except:
			traceback.print_exc()
	
	def abort(self):
		if self.child_pid is not None:
			info("Killing download process %s", self.child_pid)
			import signal
			os.kill(self.child_pid, signal.SIGTERM)
		else:
			self.status = download_failed

	def get_current_fraction(self):
		"""Returns the current fraction of this download that has been fetched (from 0 to 1),
		or None if the total size isn't known."""
		if self.status is download_starting:
			return 0
		if self.tempfile is None:
			return 1
		if self.expected_size is None:
			return None		# Unknown
		current_size = self.get_bytes_downloaded_so_far()
		return float(current_size) / self.expected_size
	
	def get_bytes_downloaded_so_far(self):
		if self.status is download_starting:
			return 0
		elif self.status is download_fetching:
			return os.fstat(self.tempfile.fileno()).st_size
		else:
			return self._final_total_size
	
	def __str__(self):
		return "<Download from %s>" % self.url
