class UI:
	def report_failed_download(self, interface, download, ex):
		"""Failed to download interface. Report to user."""
		print >>sys.stderr, "Failed to download interface '%s'" % interface.uri
		print >>sys.stderr, "Error: " + ex
	
	def download_started(self, download):
		print "New download", download

	def download_ended(self, download):
		print "Finished download", download

	def get_signed_data(self, stream):
		"""Stream is a GPG-signed message. Check that the signature is trusted
		and return the interface XML file."""
		import gpg
		return gpg.check_stream(stream)
