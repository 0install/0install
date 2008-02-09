import gtk, os, gobject, sys

from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector.policy import Policy
from zeroinstall.injector import download, handler
from zeroinstall.injector.model import SafeException
from zeroinstall.injector.reader import InvalidInterface
from zeroinstall.support import tasks, pretty_size
import dialog

version = '0.31'

class GUIHandler(handler.Handler):
	dl_callbacks = None		# Download -> [ callback ]
	pulse = None
	mainwindow = None

	def downloads_changed(self):
		if self.monitored_downloads and self.pulse is None:
			def pulse():
				progress = self.mainwindow.progress

				any_known = False
				done = total = self.total_bytes_downloaded	# Completed downloads
				n_downloads = self.n_completed_downloads
				# Now add downloads in progress...
				for x in self.monitored_downloads.values():
					if x.status != download.download_fetching: continue
					n_downloads += 1
					if x.expected_size:
						any_known = True
					so_far = x.get_bytes_downloaded_so_far()
					total += x.expected_size or max(4096, so_far)	# Guess about 4K for feeds/icons
					done += so_far

				progress_text = '%s / %s' % (pretty_size(done), pretty_size(total))
				if n_downloads == 1:
					progress.set_text('Downloading one file (%s)' % progress_text)
				else:
					progress.set_text('Downloading %d files (%s)' % (n_downloads, progress_text))

				if total == 0 or (n_downloads < 2 and not any_known):
					progress.pulse()
				else:
					progress.set_fraction(float(done) / total)

				return True
			pulse()
			self.pulse = gobject.timeout_add(50, pulse)
			self.mainwindow.progress.show()
		elif len(self.monitored_downloads) == 0:
			# Reset counters
			self.n_completed_downloads = 0
			self.total_bytes_downloaded = 0

			# Stop animation
			if self.pulse:
				gobject.source_remove(self.pulse)
				self.mainwindow.progress.hide()
				self.pulse = None

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		return trust_box.confirm_trust(interface, sigs, iface_xml, parent = self.mainwindow.window)
	
	def report_error(self, ex):
		dialog.alert(None, str(ex))
