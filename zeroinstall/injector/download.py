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
import traceback
from logging import warn

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_checking = "checking"	# Checking GPG sig (possibly interactive)
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

class DownloadError(SafeException):
	pass

class Download(object):
	__slots__ = ['url', 'tempfile', 'status', 'errors', 'expected_size',
		     'expected_size', 'child_pid', 'child_stderr', 'on_success']

	def __init__(self, url):
		"Initial status is starting."
		self.url = url
		self.status = download_starting
		self.on_success = []

		self.tempfile = None		# Stream for result
		self.errors = None

		self.expected_size = None	# Final size (excluding skipped bytes)

		self.child_pid = None
		self.child_stderr = None
	
	def start(self):
		"""Returns stderr stream from child. Call error_stream_closed() when
		it returns EOF."""
		assert self.status == download_starting
		self.tempfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-')

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
		return os.fdopen(error_r, 'r')
	
	def download_as_child(self):
		from urllib2 import urlopen, HTTPError, URLError
		try:
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
	
	def error_stream_data(self, data):
		"""Passed with result of os.read(error_stream, n). Can be
		called multiple times, once for each read."""
		assert data
		assert self.status is download_fetching
		self.errors += data

	def error_stream_closed(self):
		"""Ends a download. Status changes from fetching to checking.
		Calls the on_success callbacks with the rewound data stream on success,
		or throws DownloadError on failure."""
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

		stream = self.tempfile
		self.tempfile = None

		if errors:
			error = DownloadError(errors)
		else:	
			error = None

		# Check that the download has the correct size, if we know what it should be.
		if self.expected_size is not None and not error:
			size = os.fstat(stream.fileno()).st_size
			if size != self.expected_size:
				error = SafeException('Downloaded archive has incorrect size.\n'
						'URL: %s\n'
						'Expected: %d bytes\n'
						'Received: %d bytes' % (self.url, self.expected_size, size))

		if error:
			self.status = download_failed
			self.on_success = []	# Break GC cycles
			raise error
		else:
			self.status = download_checking

		for x in self.on_success:
			stream.seek(0)
			x(stream)
	
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
		current_size = os.fstat(self.tempfile.fileno()).st_size
		return float(current_size) / self.expected_size
