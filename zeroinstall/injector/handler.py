"""
Integrates download callbacks with an external mainloop.

While things are being downloaded, Zero Install returns control to your program.
Your mainloop is responsible for monitoring the state of the downloads and notifying
Zero Install when they are complete.

To do this, you supply a L{Handler} to the L{policy}.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
from logging import debug, info

from zeroinstall.injector import model, download
from zeroinstall.injector.iface_cache import iface_cache

class Handler(object):
	__slots__ = ['monitored_downloads']
	def __init__(self):
		self.monitored_downloads = {}		# URL -> (error_stream, Download)

	def monitor_download(self, dl):
		error_stream = dl.start()
		self.monitored_downloads[dl.url] = (error_stream, dl)
	
	def wait_for_downloads(self):
		while self.monitored_downloads:
			info("Currently downloading:")
			for url in self.monitored_downloads:
				info("- " + url)

			for e, dl in self.monitored_downloads.values():
				errors = e.read()
				if errors:
					dl.error_stream_data(errors)
					continue
				e.close()
				del self.monitored_downloads[dl.url]

				dl.error_stream_closed()

	def get_download(self, url, force = False):
		"""Return the Download object currently downloading 'url'.
		If no download for this URL has been started, start one now.
		If the download failed and force is False, return it anyway.
		If force is True, abort any current or failed download and start
		a new one."""
		try:
			e, dl = self.monitored_downloads[url]
			if dl and force:
				dl.abort()
				raise KeyError
		except KeyError:
			dl = download.Download(url)
			self.monitor_download(dl)
		return dl

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
