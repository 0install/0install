import tempfile

class Download:
	url = None
	cb = None		# Callback. cb(stream) on success, or cb(Exception) on failure.
	tempfile = None		# Stream for result

	def __init__(self, url, cb):
		self.url = url
		self.cb = cb
		self.tempfile = tempfile.TemporaryFile(prefix = 'injector-download-')
	
	def abort(self, ex):
		self.cb(ex)
	
	def done(self):
		self.tempfile.seek(0)
		self.cb(self.tempfile)
