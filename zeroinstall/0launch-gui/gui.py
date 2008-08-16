# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gobject

from zeroinstall.injector import handler, download
import dialog

version = '0.35'

class GUIHandler(handler.Handler):
	dl_callbacks = None		# Download -> [ callback ]
	pulse = None
	mainwindow = None

	def _reset_counters(self):
		if not self.monitored_downloads:
			self.n_completed_downloads = 0
			self.total_bytes_downloaded = 0
		return False

	def abort_all_downloads(self):
		for dl in self.monitored_downloads.values():
			dl.abort()

	def downloads_changed(self):
		if self.monitored_downloads and self.pulse is None:
			def pulse():
				self.mainwindow.update_download_status()
				return True
			pulse()
			self.pulse = gobject.timeout_add(50, pulse)
		elif len(self.monitored_downloads) == 0:
			# Delay before resetting, in case we start a new download quickly
			gobject.timeout_add(500, self._reset_counters)

			# Stop animation
			if self.pulse:
				gobject.source_remove(self.pulse)
				self.pulse = None
				self.mainwindow.update_download_status()
	
	def impl_added_to_store(self, impl):
		self.mainwindow.update_download_status()

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		return trust_box.confirm_trust(interface, sigs, iface_xml, parent = self.mainwindow.window)
	
	def report_error(self, ex, tb = None):
		if isinstance(ex, download.DownloadAborted):
			return		# No need to tell the user about this, since they caused it
		dialog.alert(self.mainwindow.window, str(ex))
