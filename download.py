import tempfile, os, sys
from model import Interface, DownloadSource, SafeException
import traceback
from urllib2 import urlopen

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_checking = "checking"	# Checking GPG sig (possibly interactive)
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

downloads = {}		# URL -> Download

class DownloadError(Exception):
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
		try:
			import shutil
			#print "Child downloading", self.url
			if self.url.startswith('/'):
				if not os.path.isfile(self.url):
					print >>sys.stderr, "File '%s' does not " \
						"exist!" % self.url
					return
				src = file(self.url)
				#print "Done :-)"
			elif self.url.startswith('http:'):
				src = urlopen(self.url)
			else:
				raise Exception('Unsupported URL protocol in: ' + self.url)

			shutil.copyfileobj(src, self.tempfile)
			self.tempfile.flush()
			
			os._exit(0)
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
				 'code 0x' + hex(status)

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
			print "Killing download process", self.child_pid
			import signal
			os.kill(self.child_pid, signal.SIGTERM)
		else:
			self.status = download_failed

class InterfaceDownload(Download):
	def __init__(self, interface, url = None):
		assert isinstance(interface, Interface)
		Download.__init__(self, url or interface.uri)
		self.interface = interface

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

def begin_impl_download(source, force = False):
	#print "Need to downlaod", source.url
	return _begin_download(ImplementationDownload(source), force)
	
def _begin_download(new_dl, force):
	dl = downloads.get(new_dl.url, None)
	if dl:
		if force:
			dl.abort()
			del downloads[new_dl.url]
		else:
			return None	# Already downloading
	
	downloads[new_dl.url] = new_dl

	assert new_dl.status == download_starting
	return new_dl
