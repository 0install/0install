import os, sys
from logging import debug, info

from zeroinstall.injector import model, download
from zeroinstall.injector.iface_cache import iface_cache

class Handler(object):
	__slots__ = ['monitored_downloads']
	def __init__(self):
		self.monitored_downloads = []

	def monitor_download(self, dl):
		error_stream = dl.start()
		self.monitored_downloads.append((error_stream, dl))
	
	def wait_for_downloads(self):
		while self.monitored_downloads:
			info("Currently downloading:")
			for (e, dl) in self.monitored_downloads:
				info("- " + dl.url)

			for e, dl in self.monitored_downloads[:]:
				errors = e.read()
				if errors:
					dl.error_stream_data(errors)
					continue
				e.close()
				self.monitored_downloads.remove((e, dl))
				data = dl.error_stream_closed()
				if isinstance(dl, download.InterfaceDownload):
					iface_cache.check_signed_data(dl.interface, data, self)
				elif isinstance(dl, download.ImplementationDownload):
					iface_cache.add_to_cache(dl.source, data)
				else:
					raise Exception("Unknown download type %s" % dl)

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""We don't trust any of the signatures yet. Ask the user.
		When done, call update_interface_if_trusted()."""
		import gpg
		assert sigs
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise model.SafeException('No valid signatures found. Signatures:' +
					''.join(['\n- ' + str(s) for s in sigs]))

		print "\nInterface:", interface.uri
		print "The interface is correctly signed with the following keys:"
		for x in valid_sigs:
			print "-", x
		print "Do you want to trust all of these keys to sign interfaces?"
		while True:
			i = raw_input("Trust all [Y/N] ")
			if not i: continue
			if i in 'Nn':
				raise model.SafeException('Not signed with a trusted key')
			if i in 'Yy':
				break
		from trust import trust_db
		for key in valid_sigs:
			print "Trusting", key.fingerprint
			trust_db.trust_key(key.fingerprint)

		if not iface_cache.update_interface_if_trusted(interface, sigs, iface_xml):
			raise model.Exception('Bug: still not trusted!!')
