import gobject

from zeroinstall.injector import handler
import dialog

version = '0.31'

class GUIHandler(handler.Handler):
	dl_callbacks = None		# Download -> [ callback ]
	pulse = None
	mainwindow = None

	def downloads_changed(self):
		if self.monitored_downloads and self.pulse is None:
			def pulse():
				self.mainwindow.update_download_status()
				return True
			pulse()
			self.pulse = gobject.timeout_add(50, pulse)
		elif len(self.monitored_downloads) == 0:
			# Reset counters
			self.n_completed_downloads = 0
			self.total_bytes_downloaded = 0

			# Stop animation
			if self.pulse:
				gobject.source_remove(self.pulse)
				self.pulse = None
				self.mainwindow.update_download_status()

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		return trust_box.confirm_trust(interface, sigs, iface_xml, parent = self.mainwindow.window)
	
	def report_error(self, ex):
		dialog.alert(None, str(ex))
