import sys

class UI:
	def __init__(self, policy):
		self.policy = policy

	def report_failed_download(self, interface, download, ex):
		"""Failed to download interface. Report to user."""
		print >>sys.stderr, "Failed to download interface '%s'" % interface.uri
		print >>sys.stderr, "Error:", ex
	
	def download_started(self, download):
		print "New download", download

	def download_ended(self, download):
		print "Finished download", download

	def check_signed_data(self, interface, stream):
		"""Stream is a GPG-signed message. Check that the signature is trusted
		and call policy.update_interface_from_network() when done."""
		import gpg
		data = gpg.check_stream(stream)
		self.policy.update_interface_from_network(interface, data)

	def confirm_diff(self, old, new, uri):
		import difflib
		diff = difflib.unified_diff(old.split('\n'), new.split('\n'), uri, "",
						"", "", 2, "")
		print "Updates:"
		for line in diff:
			print line

