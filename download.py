import tempfile
from model import Interface

download_starting = "starting"	# Waiting for UI to start it
download_fetching = "fetching"	# In progress
download_checking = "checking"	# Checking GPG sig (possibly interactive)
download_complete = "complete"	# Downloaded and cached OK
download_failed = "failed"

class Download:
	url = None
	tempfile = None		# Stream for result
	status = None		# download_*
	interface = None

	def __init__(self, interface, url = None):
		"Initial status is starting."
		assert isinstance(interface, Interface)
		self.url = url or interface.uri
		self.status = download_starting
		self.interface = interface
	
	def start(self):
		assert self.status == download_starting
		self.tempfile = tempfile.TemporaryFile(prefix = 'injector-download-')
		self.status = download_fetching
		return self.tempfile
	
	def get_result(self):
		"Ends a download. Status changes from fetching to checking."
		assert self.status is download_fetching
		assert self.tempfile is not None
		self.tempfile.seek(0)
		stream = self.tempfile
		self.tempfile = None
		self.status = download_fetching
		return stream
