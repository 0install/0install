"""
Integrates download callbacks with an external mainloop.
While things are being downloaded, Zero Install returns control to your program.
Your mainloop is responsible for monitoring the state of the downloads and notifying
Zero Install when they are complete.

To do this, you supply a L{Handler} to the L{policy}.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import sys
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

	__slots__ = ['monitored_downloads', '_loop', 'dry_run', 'total_bytes_downloaded', 'n_completed_downloads', '_current_confirm']

	def __init__(self, mainloop = None, dry_run = False):
		self.monitored_downloads = {}		
		self._loop = None
		self.dry_run = dry_run
		self.n_completed_downloads = 0
		self.total_bytes_downloaded = 0
		self._current_confirm = None

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
				debug(_("Entering mainloop, waiting for %s"), blocker)
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

	def confirm_keys(self, pending, fetch_key_info):
		"""We don't trust any of the signatures yet. Ask the user.
		When done update the L{trust} database, and then call L{trust.TrustDB.notify}.
		This method just calls L{confirm_import_feed} if the handler (self) is
		new-style, or L{confirm_trust_keys} for older classes. A class
		is considered old-style if it overrides confirm_trust_keys and
		not confirm_import_feed.
		@since: 0.42
		@arg pending: an object holding details of the updated feed
		@type pending: L{PendingFeed}
		@arg fetch_key_info: a function which can be used to fetch information about a key fingerprint
		@type fetch_key_info: str -> L{Blocker}
		@return: A blocker that triggers when the user has chosen, or None if already done.
		@rtype: None | L{Blocker}"""

		assert pending.sigs

		if hasattr(self.confirm_trust_keys, 'original') or not hasattr(self.confirm_import_feed, 'original'):
			# new-style class
			from zeroinstall.injector import gpg
			valid_sigs = [s for s in pending.sigs if isinstance(s, gpg.ValidSig)]
			if not valid_sigs:
				raise SafeException(_('No valid signatures found on "%(url)s". Signatures:%(signatures)s') %
						{'url': pending.url, 'signatures': ''.join(['\n- ' + str(s) for s in pending.sigs])})

			# Start downloading information about the keys...
			kfs = {}
			for sig in valid_sigs:
				kfs[sig] = fetch_key_info(sig.fingerprint)

			return self._queue_confirm_import_feed(pending, kfs)
		else:
			# old-style class
			from zeroinstall.injector import iface_cache
			import warnings
			warnings.warn(_("Should override confirm_import_feed(); using old confirm_trust_keys() for now"), DeprecationWarning, stacklevel = 2)

			iface = iface_cache.iface_cache.get_interface(pending.url)
			return self.confirm_trust_keys(iface, pending.sigs, pending.new_xml)

	@tasks.async
	def _queue_confirm_import_feed(self, pending, valid_sigs):
		# If we're already confirming something else, wait for that to finish...
		while self._current_confirm is not None:
			yield self._current_confirm

		self._current_confirm = lock = tasks.Blocker('confirm key lock')
		try:
			done = self.confirm_import_feed(pending, valid_sigs)
			yield done
			tasks.check(done)
		finally:
			self._current_confirm = None
			lock.trigger()

	@tasks.async
	def confirm_import_feed(self, pending, valid_sigs):
		"""Sub-classes should override this method to interact with the user about new feeds.
		If multiple feeds need confirmation, L{confirm_keys} will only invoke one instance of this
		method at a time.
		@param pending: the new feed to be imported
		@type pending: L{PendingFeed}
		@param valid_sigs: maps signatures to a list of fetchers collecting information about the key
		@type valid_sigs: {L{gpg.ValidSig} : L{fetch.KeyInfoFetcher}}
		@since: 0.42
		@see: L{confirm_keys}"""
		from zeroinstall.injector import trust

		assert valid_sigs

		domain = trust.domain_from_url(pending.url)

		# Ask on stderr, because we may be writing XML to stdout
		print >>sys.stderr, _("Feed: %s"), pending.url
		print >>sys.stderr, _("The feed is correctly signed with the following keys:")
		for x in valid_sigs:
			print >>sys.stderr, "-", x

		def text(parent):
			text = ""
			for node in parent.childNodes:
				if node.nodeType == node.TEXT_NODE:
					text = text + node.data
			return text

		shown = set()
		key_info_fetchers = valid_sigs.values()
		while key_info_fetchers:
			old_kfs = key_info_fetchers
			key_info_fetchers = []
			for kf in old_kfs:
				infos = set(kf.info) - shown
				if infos:
					if len(valid_sigs) > 1:
						print "%s: " % kf.fingerprint
					for info in infos:
						print >>sys.stderr, "-", text(info)
						shown.add(info)
				if kf.blocker:
					key_info_fetchers.append(kf)
			if key_info_fetchers:
				for kf in key_info_fetchers: print >>sys.stderr, kf.status
				stdin = tasks.InputBlocker(0, 'console')
				blockers = [kf.blocker for kf in key_info_fetchers] + [stdin]
				yield blockers
				for b in blockers:
					try:
						tasks.check(b)
					except Exception, ex:
						warn(_("Failed to get key info: %s"), ex)
				if stdin.happened:
					print >>sys.stderr, _("Skipping remaining key lookups due to input from user")
					break

		if len(valid_sigs) == 1:
			print >>sys.stderr, _("Do you want to trust this key to sign feeds from '%s'?") % domain
		else:
			print >>sys.stderr, _("Do you want to trust all of these keys to sign feeds from '%s'?") % domain
		while True:
			print >>sys.stderr, _("Trust [Y/N] "),
			i = raw_input()
			if not i: continue
			if i in 'Nn':
				raise NoTrustedKeys(_('Not signed with a trusted key'))
			if i in 'Yy':
				break
		for key in valid_sigs:
			print >>sys.stderr, _("Trusting %(key_fingerprint)s for %(domain)s") % {'key_fingerprint': key.fingerprint, 'domain': domain}
			trust.trust_db.trust_key(key.fingerprint, domain)

	confirm_import_feed.original = True

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""We don't trust any of the signatures yet. Ask the user.
		When done update the L{trust} database, and then call L{trust.TrustDB.notify}.
		@deprecated: see L{confirm_keys}
		@arg interface: the interface being updated
		@arg sigs: a list of signatures (from L{gpg.check_stream})
		@arg iface_xml: the downloaded data (not yet trusted)
		@return: a blocker, if confirmation will happen asynchronously, or None
		@rtype: L{tasks.Blocker}"""
		import warnings
		warnings.warn(_("Use confirm_keys, not confirm_trust_keys"), DeprecationWarning, stacklevel = 2)
		from zeroinstall.injector import trust, gpg
		assert sigs
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found on "%s". Signatures:%s' %
					(interface.uri, ''.join(['\n- ' + str(s) for s in sigs])))

		domain = trust.domain_from_url(interface.uri)

		# Ask on stderr, because we may be writing XML to stdout
		print >>sys.stderr, "\nInterface:", interface.uri
		print >>sys.stderr, "The interface is correctly signed with the following keys:"
		for x in valid_sigs:
			print >>sys.stderr, "-", x

		if len(valid_sigs) == 1:
			print >>sys.stderr, "Do you want to trust this key to sign feeds from '%s'?" % domain
		else:
			print >>sys.stderr, "Do you want to trust all of these keys to sign feeds from '%s'?" % domain
		while True:
			print >>sys.stderr, "Trust [Y/N] ",
			i = raw_input()
			if not i: continue
			if i in 'Nn':
				raise NoTrustedKeys(_('Not signed with a trusted key'))
			if i in 'Yy':
				break
		for key in valid_sigs:
			print >>sys.stderr, "Trusting", key.fingerprint, "for", domain
			trust.trust_db.trust_key(key.fingerprint, domain)

		trust.trust_db.notify()

	confirm_trust_keys.original = True		# Detect if someone overrides it

	def report_error(self, exception, tb = None):
		"""Report an exception to the user.
		@param exception: the exception to report
		@type exception: L{SafeException}
		@param tb: optional traceback
		@since: 0.25"""
		warn("%s", str(exception) or type(exception))
		#import traceback
		#traceback.print_exception(exception, None, tb)
