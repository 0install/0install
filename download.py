import tempfile, os, sys
from model import Interface
import traceback

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
	interface = None
	errors = None

	child_pid = None
	child_stderr = None

	def __init__(self, interface, url = None):
		"Initial status is starting."
		assert isinstance(interface, Interface)
		self.url = url or interface.uri
		self.status = download_starting
		self.interface = interface
	
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
		import time
		try:
			print "Child downloading", self.url
			#time.sleep(1)
			if not os.path.isfile(self.url):
				print >>sys.stderr, "File '%s' does not " \
					"exist!" % self.url
				return
			import shutil
			shutil.copyfileobj(file(self.url), self.tempfile)
			self.tempfile.flush()
			#print "Done :-)"
			
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
	
def begin_download(interface, force):
	"""Start downloading interface.
	If a Download object already exists (any state; in progress, failed or
	completed) and force is False, does nothing and returns None.
	If force is True, any existing download is destroyed and a new one created."""
	dl = downloads.get(interface.uri, None)
	if dl:
		if force:
			dl.abort()
			del downloads[interface.uri]
		else:
			return None	# Already downloading
	
	#print "Creating new Download(%s)" % interface.uri
	# Create new download
	dl = Download(interface)
	downloads[interface.uri] = dl

	assert dl.status == download_starting
	return dl
