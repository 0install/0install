class UI:
	def __init__(self, policy):
		self.policy = policy

	def start_download(self, download):
		print "New download", download

	def check_signed_data(self, download):
		"""Downloaded data is a GPG-signed message. Check that the signature is trusted
		and call policy.update_interface_from_network() when done."""
		import gpg
		data = gpg.check_stream(download.get_result())
		self.policy.update_interface_from_network(download.interface, data)

	def confirm_diff(self, old, new, uri):
		import difflib
		diff = difflib.unified_diff(old.split('\n'), new.split('\n'), uri, "",
						"", "", 2, "")
		print "Updates:"
		for line in diff:
			print line

