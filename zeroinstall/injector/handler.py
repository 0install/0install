"""
Integrates download callbacks with an external mainloop.
While things are being downloaded, Zero Install returns control to your program.
Your mainloop is responsible for monitoring the state of the downloads and notifying
Zero Install when they are complete.

To do this, you supply a L{Handler} to the L{policy}.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from logging import debug, warn

from zeroinstall import NeedDownload, SafeException
from zeroinstall.support import tasks
from zeroinstall.injector import download

class NoTrustedKeys(SafeException):
	"""Thrown by L{Handler.confirm_trust_keys} on failure."""
	pass

class Handler(object):
	"""
	This implementation uses the GLib mainloop. Note that QT4 can use the GLib mainloop too.

	@ivar monitored_downloads: dict of downloads in progress
	@type monitored_downloads: {URL: L{download.Download}}
	@ivar n_completed_downloads: number of downloads which have finished for GUIs, etc (can be reset as desired).
	@type n_completed_downloads: int
	@ivar total_bytes_downloaded: informational counter for GUIs, etc (can be reset as desired). Updated when download finishes.
	@type total_bytes_downloaded: int
	"""

	__slots__ = ['monitored_downloads', '_loop', 'dry_run', 'total_bytes_downloaded', 'n_completed_downloads']

	def __init__(self, mainloop = None, dry_run = False):
		self.monitored_downloads = {}		
		self._loop = None
		self.dry_run = dry_run
		self.n_completed_downloads = 0
		self.total_bytes_downloaded = 0
	
	def monitor_download(self, dl):
		"""Called when a new L{download} is started.
		This is mainly used by the GUI to display the progress bar."""
		dl.start()
		self.monitored_downloads[dl.url] = dl
		self.downloads_changed()

		@tasks.async
		def download_done_stats():
			yield dl.downloaded
			# NB: we don't check for exceptions here; someone else should be doing that
			try:
				self.n_completed_downloads += 1
				self.total_bytes_downloaded += dl.get_bytes_downloaded_so_far()
				del self.monitored_downloads[dl.url]
				self.downloads_changed()
			except Exception, ex:
				self.report_error(ex)
		download_done_stats()

	def impl_added_to_store(self, impl):
		"""Called by the L{fetch.Fetcher} when adding an implementation.
		The GUI uses this to update its display.
		@param impl: the implementation which has been added
		@type impl: L{model.Implementation}
		"""
		pass
	
	def downloads_changed(self):
		"""This is just for the GUI to override to update its display."""
		pass
	
	def wait_for_blocker(self, blocker):
		"""Run a recursive mainloop until blocker is triggered.
		@param blocker: event to wait on
		@type blocker: L{tasks.Blocker}"""
		if not blocker.happened:
			import gobject

			def quitter():
				yield blocker
				self._loop.quit()
			quit = tasks.Task(quitter(), "quitter")

			assert self._loop is None	# Avoid recursion
			self._loop = gobject.MainLoop(gobject.main_context_default())
			try:
				debug("Entering mainloop, waiting for %s", blocker)
				self._loop.run()
			finally:
				self._loop = None

			assert blocker.happened, "Someone quit the main loop!"

		tasks.check(blocker)
	
	def get_download(self, url, force = False, hint = None):
		"""Return the Download object currently downloading 'url'.
		If no download for this URL has been started, start one now (and
		start monitoring it).
		If the download failed and force is False, return it anyway.
		If force is True, abort any current or failed download and start
		a new one.
		@rtype: L{download.Download}
		"""
		if self.dry_run:
			raise NeedDownload(url)

		try:
			dl = self.monitored_downloads[url]
			if dl and force:
				dl.abort()
				raise KeyError
		except KeyError:
			dl = download.Download(url, hint)
			self.monitor_download(dl)
		return dl

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""We don't trust any of the signatures yet. Ask the user.
		When done update the L{trust} database, and then call L{trust.TrustDB.notify}.
		@arg interface: the interface being updated
		@arg sigs: a list of signatures (from L{gpg.check_stream})
		@arg iface_xml: the downloaded data (not yet trusted)
		@return: a blocker, if confirmation will happen asynchronously, or None
		@rtype: L{tasks.Blocker}"""
		from zeroinstall.injector import trust, gpg
		assert sigs
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found. Signatures:' +
					''.join(['\n- ' + str(s) for s in sigs]))

		domain = trust.domain_from_url(interface.uri)

		print "\nInterface:", interface.uri
		print "The interface is correctly signed with the following keys:"
		for x in valid_sigs:
			print "-", x

		if len(valid_sigs) == 1:
			print "Do you want to trust this key to sign feeds from '%s'?" % domain
		else:
			print "Do you want to trust all of these keys to sign feeds from '%s'?" % domain
		while True:
			i = raw_input("Trust [Y/N] ")
			if not i: continue
			if i in 'Nn':
				raise NoTrustedKeys('Not signed with a trusted key')
			if i in 'Yy':
				break
		for key in valid_sigs:
			print "Trusting", key.fingerprint, "for", domain
			trust.trust_db.trust_key(key.fingerprint, domain)

		trust.trust_db.notify()
	
	def report_error(self, exception, tb = None):
		"""Report an exception to the user.
		@param exception: the exception to report
		@type exception: L{SafeException}
		@param tb: optional traceback
		@since: 0.25"""
		warn("%s", exception)
		#import traceback
		#traceback.print_exception(exception, None, tb)
