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
from logging import debug, warn, info

from zeroinstall import NeedDownload, SafeException
from zeroinstall.support import tasks
from zeroinstall.injector import download

KEY_INFO_TIMEOUT = 10	# Maximum time to wait for response from key-info-server

class NoTrustedKeys(SafeException):
	"""Thrown by L{Handler.confirm_import_feed} on failure."""
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
	@ivar dry_run: instead of starting a download, just report what we would have downloaded
	@type dry_run: bool
	"""

	__slots__ = ['monitored_downloads', 'dry_run', 'total_bytes_downloaded', 'n_completed_downloads', '_current_confirm']

	def __init__(self, mainloop = None, dry_run = False):
		self.monitored_downloads = {}		
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
		"""@deprecated: use tasks.wait_for_blocker instead"""
		tasks.wait_for_blocker(blocker)
	
	def get_download(self, url, force = False, hint = None, factory = None):
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
			if factory is None:
				dl = download.Download(url, hint)
			else:
				dl = factory(url, hint)
			self.monitor_download(dl)
		return dl

	def confirm_keys(self, pending, fetch_key_info):
		"""We don't trust any of the signatures yet. Ask the user.
		When done update the L{trust} database, and then call L{trust.TrustDB.notify}.
		This method starts downloading information about the signing keys and calls L{confirm_import_feed}.
		@since: 0.42
		@arg pending: an object holding details of the updated feed
		@type pending: L{PendingFeed}
		@arg fetch_key_info: a function which can be used to fetch information about a key fingerprint
		@type fetch_key_info: str -> L{Blocker}
		@return: A blocker that triggers when the user has chosen, or None if already done.
		@rtype: None | L{Blocker}"""

		assert pending.sigs

		from zeroinstall.injector import gpg
		valid_sigs = [s for s in pending.sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			def format_sig(sig):
				msg = str(sig)
				if sig.messages:
					msg += "\nMessages from GPG:\n" + sig.messages
				return msg
			raise SafeException(_('No valid signatures found on "%(url)s". Signatures:%(signatures)s') %
					{'url': pending.url, 'signatures': ''.join(['\n- ' + format_sig(s) for s in pending.sigs])})

		# Start downloading information about the keys...
		kfs = {}
		for sig in valid_sigs:
			kfs[sig] = fetch_key_info(sig.fingerprint)

		return self._queue_confirm_import_feed(pending, kfs)

	@tasks.async
	def _queue_confirm_import_feed(self, pending, valid_sigs):
		# Wait up to KEY_INFO_TIMEOUT seconds for key information to arrive. Avoids having the dialog
		# box update while the user is looking at it, and may allow it to be skipped completely in some
		# cases.
		timeout = tasks.TimeoutBlocker(KEY_INFO_TIMEOUT, "key info timeout")
		while True:
			key_info_blockers = [sig_info.blocker for sig_info in valid_sigs.values() if sig_info.blocker is not None]
			if not key_info_blockers:
				break
			info("Waiting for response from key-info server: %s", key_info_blockers)
			yield [timeout] + key_info_blockers
			if timeout.happened:
				info("Timeout waiting for key info response")
				break

		# If we're already confirming something else, wait for that to finish...
		while self._current_confirm is not None:
			info("Waiting for previous key confirmations to finish")
			yield self._current_confirm

		# Check whether we still need to confirm. The user may have
		# already approved one of the keys while dealing with another
		# feed.
		from zeroinstall.injector import trust
		domain = trust.domain_from_url(pending.url)
		for sig in valid_sigs:
			is_trusted = trust.trust_db.is_trusted(sig.fingerprint, domain)
			if is_trusted:
				return

		# Take the lock and confirm this feed
		self._current_confirm = lock = tasks.Blocker('confirm key lock')
		try:
			done = self.confirm_import_feed(pending, valid_sigs)
			if done is not None:
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
		print >>sys.stderr, _("Feed: %s") % pending.url
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
					for key_info in infos:
						print >>sys.stderr, "-", text(key_info)
						shown.add(key_info)
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

	@tasks.async
	def confirm_install(self, msg):
		"""We need to check something with the user before continuing with the install.
		@raise download.DownloadAborted: if the user cancels"""
		yield
		print >>sys.stderr, msg
		while True:
			sys.stderr.write(_("Install [Y/N] "))
			i = raw_input()
			if not i: continue
			if i in 'Nn':
				raise download.DownloadAborted()
			if i in 'Yy':
				break

	def report_error(self, exception, tb = None):
		"""Report an exception to the user.
		@param exception: the exception to report
		@type exception: L{SafeException}
		@param tb: optional traceback
		@since: 0.25"""
		warn("%s", str(exception) or type(exception))
		#import traceback
		#traceback.print_exception(exception, None, tb)

class ConsoleHandler(Handler):
	"""A Handler that displays progress on stdout (a tty).
	@since: 0.44"""
	last_msg_len = None
	update = None
	disable_progress = 0
	screen_width = None

	def downloads_changed(self):
		import gobject
		if self.monitored_downloads and self.update is None:
			if self.screen_width is None:
				try:
					import curses
					curses.setupterm()
					self.screen_width = curses.tigetnum('cols') or 80
				except Exception, ex:
					info("Failed to initialise curses library: %s", ex)
					self.screen_width = 80
			self.show_progress()
			self.update = gobject.timeout_add(200, self.show_progress)
		elif len(self.monitored_downloads) == 0:
			if self.update:
				gobject.source_remove(self.update)
				self.update = None
				print
				self.last_msg_len = None

	def show_progress(self):
		urls = self.monitored_downloads.keys()
		if not urls: return True

		if self.disable_progress: return True

		screen_width = self.screen_width - 2
		item_width = max(16, screen_width / len(self.monitored_downloads))
		url_width = item_width - 7

		msg = ""
		for url in sorted(urls):
			dl = self.monitored_downloads[url]
			so_far = dl.get_bytes_downloaded_so_far()
			leaf = url.rsplit('/', 1)[-1]
			if len(leaf) >= url_width:
				display = leaf[:url_width]
			else:
				display = url[-url_width:]
			if dl.expected_size:
				msg += "[%s %d%%] " % (display, int(so_far * 100 / dl.expected_size))
			else:
				msg += "[%s] " % (display)
		msg = msg[:screen_width]

		if self.last_msg_len is None:
			sys.stdout.write(msg)
		else:
			sys.stdout.write(chr(13) + msg)
			if len(msg) < self.last_msg_len:
				sys.stdout.write(" " * (self.last_msg_len - len(msg)))

		self.last_msg_len = len(msg)
		sys.stdout.flush()

		return True

	def clear_display(self):
		if self.last_msg_len != None:
			sys.stdout.write(chr(13) + " " * self.last_msg_len + chr(13))
			sys.stdout.flush()
			self.last_msg_len = None

	def report_error(self, exception, tb = None):
		self.clear_display()
		Handler.report_error(self, exception, tb)

	def confirm_import_feed(self, pending, valid_sigs):
		self.clear_display()
		self.disable_progress += 1
		blocker = Handler.confirm_import_feed(self, pending, valid_sigs)
		@tasks.async
		def enable():
			yield blocker
			self.disable_progress -= 1
			self.show_progress()
		enable()
		return blocker
