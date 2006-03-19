# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import tempfile, os, sys
from model import Interface, DownloadSource, SafeException, escape
import traceback
from logging import warn
from namespaces import config_site

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_checking = "checking"	# Checking GPG sig (possibly interactive)
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

_downloads = {}		# URL -> Download

class DownloadError(SafeException):
	pass

class Download:
	url = None
	tempfile = None		# Stream for result
	status = None		# download_*
	errors = None

	child_pid = None
	child_stderr = None

	def __init__(self, url):
		"Initial status is starting."
		self.url = url
		self.status = download_starting
	
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
		Returns data stream."""
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
			self.status = download_failed
			raise DownloadError(errors)
		else:
			self.status = download_checking

		stream.seek(0)
		return stream
	
	def abort(self):
		if self.child_pid is not None:
			warn("Killing download process %s", self.child_pid)
			import signal
			os.kill(self.child_pid, signal.SIGTERM)
		else:
			self.status = download_failed

class InterfaceDownload(Download):
	def __init__(self, interface, url = None):
		assert isinstance(interface, Interface)
		Download.__init__(self, url or interface.uri)
		self.interface = interface

class IconDownload(Download):
	def __init__(self, interface, source, url = None):
		assert isinstance(interface, Interface)
		Download.__init__(self, source)
		self.interface = interface

	def error_stream_closed(self):
		from zeroinstall.injector import basedir
		import shutil
		stream = Download.error_stream_closed(self)
		icons_cache = basedir.save_cache_path(config_site, 'interface_icons')
		icon_file = file(os.path.join(icons_cache, escape(self.interface.uri)), 'w')

		shutil.copyfileobj(stream, icon_file)

class ImplementationDownload(Download):
	def __init__(self, source):
		assert isinstance(source, DownloadSource)
		Download.__init__(self, source.url)
		self.source = source
	
	def error_stream_closed(self):
		stream = Download.error_stream_closed(self)
		size = os.fstat(stream.fileno()).st_size
		if size != self.source.size:
			raise SafeException('Downloaded archive has incorrect size.\n'
					'URL: %s\n'
					'Expected: %d bytes\n'
					'Received: %d bytes' % (self.url, self.source.size, size))
		return stream
	
	def get_current_fraction(self):
		if self.status is download_starting:
			return 0
		if self.tempfile is None:
			return 1
		current_size = os.fstat(self.tempfile.fileno()).st_size
		return float(current_size) / self.source.size
	
def begin_iface_download(interface, force):
	"""Start downloading interface.
	If a Download object already exists (any state; in progress, failed or
	completed) and force is False, does nothing and returns None.
	If force is True, any existing download is destroyed and a new one created."""
	return _begin_download(InterfaceDownload(interface), force)

path_dirs = os.environ.get('PATH', '/bin:/usr/bin').split(':')
def _available_in_path(command):
	for x in path_dirs:
		if os.path.isfile(os.path.join(x, command)):
			return True
	return False

def begin_impl_download(source, force = False):
	#print "Need to downlaod", source.url
	if source.url.endswith('.rpm'):
		if not _available_in_path('rpm2cpio'):
			raise SafeException("The URL '%s' looks like an RPM, but you don't have the rpm2cpio command "
					"I need to extract it. Install the 'rpm' package first (this works even if "
					"you're on a non-RPM-based distribution such as Debian)." % source.url)
	return _begin_download(ImplementationDownload(source), force)
	
def begin_icon_download(interface, source, force = False):
	return _begin_download(IconDownload(interface, source), force)
	
def _begin_download(new_dl, force):
	dl = _downloads.get(new_dl.url, None)
	if dl:
		if force:
			dl.abort()
			del _downloads[new_dl.url]
		else:
			return None	# Already downloading
	
	_downloads[new_dl.url] = new_dl

	assert new_dl.status == download_starting
	return new_dl
