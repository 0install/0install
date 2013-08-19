"""
Integrates download callbacks with an external mainloop.
While things are being downloaded, Zero Install returns control to your program.
Your mainloop is responsible for monitoring the state of the downloads and notifying
Zero Install when they are complete.

To do this, you supply a L{Handler} to the L{policy}.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _, logger
import sys

if sys.version_info[0] < 3:
	import __builtin__ as builtins
else:
	import builtins

from zeroinstall import SafeException
from zeroinstall import support
from zeroinstall.support import tasks
from zeroinstall.injector import download

class NoTrustedKeys(SafeException):
	"""Thrown by L{Handler.confirm_import_feed} on failure."""
	pass

class Handler(object):
	"""
	A Handler is used to interact with the user (e.g. to confirm keys, display download progress, etc).

	@ivar monitored_downloads: set of downloads in progress
	@type monitored_downloads: {L{download.Download}}
	@ivar n_completed_downloads: number of downloads which have finished for GUIs, etc (can be reset as desired).
	@type n_completed_downloads: int
	@ivar total_bytes_downloaded: informational counter for GUIs, etc (can be reset as desired). Updated when download finishes.
	@type total_bytes_downloaded: int
	@ivar dry_run: don't write or execute any files, just print notes about what we would have done to stdout
	@type dry_run: bool
	"""

	__slots__ = ['monitored_downloads', 'dry_run', 'total_bytes_downloaded', 'n_completed_downloads']

	def __init__(self, mainloop = None, dry_run = False):
		"""@type dry_run: bool"""
		self.monitored_downloads = set()
		self.dry_run = dry_run
		self.n_completed_downloads = 0
		self.total_bytes_downloaded = 0

	def monitor_download(self, dl):
		"""Called when a new L{download} is started.
		This is mainly used by the GUI to display the progress bar.
		@type dl: L{zeroinstall.injector.download.Download}"""
		self.monitored_downloads.add(dl)
		self.downloads_changed()

		@tasks.async
		def download_done_stats():
			yield dl.downloaded
			# NB: we don't check for exceptions here; someone else should be doing that
			try:
				self.n_completed_downloads += 1
				self.total_bytes_downloaded += dl.get_bytes_downloaded_so_far()
				self.monitored_downloads.remove(dl)
				self.downloads_changed()
			except Exception as ex:
				self.report_error(ex)
		download_done_stats()

	def impl_added_to_store(self, impl):
		"""Called by the L{fetch.Fetcher} when adding an implementation.
		The GUI uses this to update its display.
		@param impl: the implementation which has been added
		@type impl: L{model.Implementation}"""
		pass
	
	def downloads_changed(self):
		"""This is just for the GUI to override to update its display."""
		pass
	
	def wait_for_blocker(self, blocker):
		"""@type blocker: L{zeroinstall.support.tasks.Blocker}
		@deprecated: use tasks.wait_for_blocker instead"""
		tasks.wait_for_blocker(blocker)
	
	@tasks.async
	def confirm_import_feed(self, pending, valid_sigs):
		"""Sub-classes should override this method to interact with the user about new feeds.
		If multiple feeds need confirmation, L{trust.TrustMgr.confirm_keys} will only invoke one instance of this
		method at a time.
		@param pending: the new feed to be imported
		@type pending: L{PendingFeed}
		@param valid_sigs: maps signatures to a list of fetchers collecting information about the key
		@type valid_sigs: {L{gpg.ValidSig} : L{fetch.KeyInfoFetcher}}
		@since: 0.42"""
		from zeroinstall.injector import trust

		assert valid_sigs

		domain = trust.domain_from_url(pending.url)

		# Ask on stderr, because we may be writing XML to stdout
		print(_("Feed: %s") % pending.url, file=sys.stderr)
		print(_("The feed is correctly signed with the following keys:"), file=sys.stderr)
		for x in valid_sigs:
			print("-", x, file=sys.stderr)

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
						print("%s: " % kf.fingerprint)
					for key_info in infos:
						print("-", text(key_info), file=sys.stderr)
						shown.add(key_info)
				if kf.blocker:
					key_info_fetchers.append(kf)
			if key_info_fetchers:
				for kf in key_info_fetchers: print(kf.status, file=sys.stderr)
				stdin = tasks.InputBlocker(0, 'console')
				blockers = [kf.blocker for kf in key_info_fetchers] + [stdin]
				yield blockers
				for b in blockers:
					try:
						tasks.check(b)
					except Exception as ex:
						logger.warning(_("Failed to get key info: %s"), ex)
				if stdin.happened:
					print(_("Skipping remaining key lookups due to input from user"), file=sys.stderr)
					break
		if not shown:
			print(_("Warning: Nothing known about this key!"), file=sys.stderr)

		if len(valid_sigs) == 1:
			print(_("Do you want to trust this key to sign feeds from '%s'?") % domain, file=sys.stderr)
		else:
			print(_("Do you want to trust all of these keys to sign feeds from '%s'?") % domain, file=sys.stderr)
		while True:
			print(_("Trust [Y/N] "), end=' ', file=sys.stderr)
			sys.stderr.flush()
			i = support.raw_input()
			if not i: continue
			if i in 'Nn':
				raise NoTrustedKeys(_('Not signed with a trusted key'))
			if i in 'Yy':
				break
		trust.trust_db._dry_run = self.dry_run
		for key in valid_sigs:
			print(_("Trusting %(key_fingerprint)s for %(domain)s") % {'key_fingerprint': key.fingerprint, 'domain': domain}, file=sys.stderr)
			trust.trust_db.trust_key(key.fingerprint, domain)

	@tasks.async
	def confirm_install(self, msg):
		"""We need to check something with the user before continuing with the install.
		@raise download.DownloadAborted: if the user cancels"""
		yield
		print(msg, file=sys.stderr)
		while True:
			sys.stderr.write(_("Install [Y/N] "))
			sys.stderr.flush()
			i = support.raw_input()
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
		import logging
		logger.warning("%s", str(exception) or type(exception),
				exc_info = (exception, exception, tb) if logger.isEnabledFor(logging.INFO) else None)
	
class ConsoleHandler(Handler):
	"""A Handler that displays progress on stderr (a tty).
	(we use stderr because we use stdout to talk to the OCaml process)
	@since: 0.44"""
	last_msg_len = None
	update = None
	disable_progress = 0
	screen_width = None

	# While we are displaying progress, we override builtins.print to clear the display first.
	original_print = None

	def downloads_changed(self):
		if self.monitored_downloads and self.update is None:
			if self.screen_width is None:
				try:
					import curses
					curses.setupterm()
					self.screen_width = curses.tigetnum('cols') or 80
				except Exception as ex:
					logger.info("Failed to initialise curses library: %s", ex)
					self.screen_width = 80
			self.show_progress()
			self.original_print = print
			builtins.print = self.print
			self.update = tasks.get_loop().call_repeatedly(0.2, self.show_progress)
		elif len(self.monitored_downloads) == 0:
			if self.update:
				self.update.cancel()
				self.update = None
				builtins.print = self.original_print
				self.original_print = None
				self.clear_display()

	def show_progress(self):
		if not self.monitored_downloads: return
		urls = [(dl.url, dl) for dl in self.monitored_downloads]

		if self.disable_progress: return

		screen_width = self.screen_width - 2
		item_width = max(16, screen_width // len(self.monitored_downloads))
		url_width = item_width - 7

		msg = ""
		for url, dl in sorted(urls):
			so_far = dl.get_bytes_downloaded_so_far()
			if url.endswith('/latest.xml'):
				url = url[:-10]		# remove latest.xml from mirror URLs
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
			sys.stderr.write(msg)
		else:
			sys.stderr.write(chr(13) + msg)
			if len(msg) < self.last_msg_len:
				sys.stderr.write(" " * (self.last_msg_len - len(msg)))

		self.last_msg_len = len(msg)
		sys.stderr.flush()

		return

	def clear_display(self):
		if self.last_msg_len != None:
			sys.stderr.write(chr(13) + " " * self.last_msg_len + chr(13))
			sys.stderr.flush()
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

	def print(self, *args, **kwargs):
		self.clear_display()
		self.original_print(*args, **kwargs)
