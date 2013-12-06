# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
from zeroinstall.support import tasks
from zeroinstall.injector import handler, download

gobject = tasks.get_loop().gobject
glib = tasks.get_loop().glib

version = '2.5.1-post'

class GUIHandler(handler.Handler):
	pulse = None
	mainwindow = None

	def _reset_counters(self):
		if not self.monitored_downloads:
			self.n_completed_downloads = 0
			self.total_bytes_downloaded = 0
		return False

	def abort_all_downloads(self):
		for dl in self.monitored_downloads:
			dl.abort()

	def downloads_changed(self):
		if self.monitored_downloads and self.pulse is None:
			def pulse():
				self.mainwindow.update_download_status(only_update_visible = True)
				return True
			pulse()
			self.pulse = glib.timeout_add(200, pulse)
		elif len(self.monitored_downloads) == 0:
			# Delay before resetting, in case we start a new download quickly
			glib.timeout_add(500, self._reset_counters)

			# Stop animation
			if self.pulse:
				glib.source_remove(self.pulse)
				self.pulse = None
				self.mainwindow.update_download_status()

	@tasks.async
	def _switch_to_main_window(self, reason):
		if self.mainwindow.systray_icon:
			self.mainwindow.systray_icon.set_tooltip(reason)
			self.mainwindow.systray_icon.set_blinking(True)

			# Wait for the user to click the icon, then continue
			yield self.mainwindow.systray_icon_blocker
			yield tasks.TimeoutBlocker(0.5, 'Delay')
