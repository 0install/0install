# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gobject

from zeroinstall.support import tasks
from zeroinstall.injector import handler, download

version = '0.51'

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
			self.pulse = gobject.timeout_add(200, pulse)
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

	@tasks.async
	def _switch_to_main_window(self, reason):
		if self.mainwindow.systray_icon:
			self.mainwindow.systray_icon.set_tooltip(reason)
			self.mainwindow.systray_icon.set_blinking(True)

			# Wait for the user to click the icon, then continue
			yield self.mainwindow.systray_icon_blocker
			yield tasks.TimeoutBlocker(0.5, 'Delay')

	@tasks.async
	def confirm_import_feed(self, pending, valid_sigs):
		yield self._switch_to_main_window(_('Need to confirm a new GPG key'))

		from zeroinstall.gtkui import trust_box
		box = trust_box.TrustBox(pending, valid_sigs, parent = self.mainwindow.window)
		box.show()
		yield box.closed

	@tasks.async
	def confirm_install(self, message):
		yield self._switch_to_main_window(_('Need to confirm installation of distribution packages'))

		from zeroinstall.injector.download import DownloadAborted
		import dialog
		import gtk
		box = gtk.MessageDialog(self.mainwindow.window,
					gtk.DIALOG_DESTROY_WITH_PARENT,
					gtk.MESSAGE_QUESTION, gtk.BUTTONS_CANCEL,
					str(message))
		box.set_position(gtk.WIN_POS_CENTER)

		install = dialog.MixedButton(_('Install'), gtk.STOCK_OK)
		install.set_flags(gtk.CAN_DEFAULT)
		box.add_action_widget(install, gtk.RESPONSE_OK)
		install.show_all()
		box.set_default_response(gtk.RESPONSE_OK)
		box.show()

		response = dialog.DialogResponse(box)
		yield response
		box.destroy()

		if response.response != gtk.RESPONSE_OK:
			raise DownloadAborted()

	def report_error(self, ex, tb = None):
		if isinstance(ex, download.DownloadAborted):
			return		# No need to tell the user about this, since they caused it
		self.mainwindow.report_exception(ex, tb = tb)
