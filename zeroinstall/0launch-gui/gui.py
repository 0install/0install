import gtk, os, gobject, sys

from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector.policy import Policy
from zeroinstall.injector import download, handler
from zeroinstall.injector.model import SafeException
from zeroinstall.injector.reader import InvalidInterface
import dialog
from checking import CheckingBox

version = '0.26'

# Singleton Policy
policy = None

class GUIHandler(object):
	monitored_downloads = None
	dl_callbacks = None		# Download -> [ callback ]
	pulse = None
	policy = None

	def __init__(self, policy):
		self.policy = policy
		self.monitored_downloads = []
		self.dl_callbacks = {}

	def get_download(self, url, force = False):
		dl = None
		for dl in self.monitored_downloads:
			if dl.url == url:
				if force:
					dl.abort()
					dl = None
				break
		else:
			dl = None
		if dl is None:
			dl = download.Download(url)
			self.monitor_download(dl)
		return dl
	
	def add_dl_callback(self, url, callback):
		"""If url is being downloaded now, call callback() when it completes.
		Otherwise, call callback() now."""
		for dl in self.monitored_downloads:
			if dl.url == url:
				callbacks = self.dl_callbacks.get(dl, [])
				callbacks.append(callback)
				self.dl_callbacks[dl] = callbacks
				return
		callback()

	def monitor_download(self, dl):
		from zeroinstall.injector import download
		name = os.path.basename(dl.url)

		self.monitored_downloads.append(dl)

		error_stream = dl.start()
		def error_ready(src, cond):
			got = os.read(src.fileno(), 100)
			if not got:
				error_stream.close()
				self.monitored_downloads.remove(dl)
				if len(self.monitored_downloads) == 0:
					gobject.source_remove(self.pulse)
					self.policy.window.progress.hide()
					self.pulse = None
				try:
					dl.error_stream_closed()
					if hasattr(download, 'IconDownload') and \
					     isinstance(dl, download.IconDownload):
						if self.policy.window:
							self.policy.window.browser.build_tree()
				except download.DownloadError, ex:
					dialog.alert(self.policy.window,
						"Error downloading '%s':\n\n%s" %
						(name, ex))
				except InvalidInterface, ex:
					dialog.alert(self.policy.window,
						"Syntax error in downloaded interface '%s':\n\n%s" %
						(name, ex))
				except SafeException, ex:
					dialog.alert(self.policy.window,
						"Error fetching '%s':\n\n%s" %
						(name, ex))

				for cb in self.dl_callbacks.get(dl, []):
					cb()

				if len(self.monitored_downloads) == 0 and self.policy.checking:
					self.policy.checking.updates_done(self.policy.versions_changed())
				return False
			dl.error_stream_data(got)
			return True

		gobject.io_add_watch(error_stream,
				     gobject.IO_IN | gobject.IO_HUP,
				     error_ready)

		if self.pulse is None:
			def pulse():
				if self.policy.checking:
					self.policy.checking.progress.pulse()
				else:
					self.policy.window.progress.pulse()
				return True
			self.pulse = gobject.timeout_add(50, pulse)
			self.policy.window.progress.show()

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		trust_box.confirm_trust(interface, sigs, iface_xml)
	
	def report_error(self, ex):
		dialog.alert(None, str(ex))

class GUIPolicy(Policy):
	window = None
	checking = None		# GtkDialog ("Checking for updates...")
	original_implementation = None
	download_only = None

	def __init__(self, interface, download_only, refresh, src = False, restrictions = None):
		Policy.__init__(self, interface, GUIHandler(self), src = src)
		global policy
		assert policy is None
		policy = self

		if restrictions:
			for r in restrictions:
				self.root_restrictions.append(r)

		self.download_only = download_only

		import mainwindow
		self.window = mainwindow.MainWindow(download_only)
		root = iface_cache.get_interface(self.root)
		self.window.browser.set_root(root)

		if refresh:
			# If we have feeds then treat this as a refresh,
			# even if we've never seen the main interface before.
			# Used the first time the GUI is used, for example.
			if root.name is not None or root.feeds:
				self.checking = CheckingBox(root)

			self.refresh_all(force = False)
	
	def show_details(self):
		"""The checking box has disappeared. Should we show the details window, or
		just run the program right now?"""
		if self.checking.show_details:
			return True		# User clicked on the Details button
		if not self.ready:
			return True		# Not ready to start (can't find an implementation)
		if self.versions_changed():
			return True		# Confirm that the new version should be used
		if self.get_uncached_implementations():
			return True		# Need to download something; check first
		return False

	def store_icon(self, interface, stream):
		Policy.store_icon(self, interface, stream)
		if self.window:
			self.window.browser.build_tree()
	
	def recalculate(self, fetch_stale_interfaces = True):
		Policy.recalculate(self, fetch_stale_interfaces)
		self.window.set_response_sensitive(gtk.RESPONSE_OK, self.ready)

	def main(self):
		if self.checking:
			self.checking.show()
			if not self.handler.monitored_downloads:
				self.checking.updates_done(self.versions_changed())
			dialog.wait_for_no_windows()
			show_details = self.show_details()
			self.checking = None
			if show_details:
				self.window.show()
				gtk.main()
			else:
				import download_box
				download_box.download_with_gui(self.window)
		else:
			self.window.show()
			gtk.main()
	
	def abort_all_downloads(self):
		for x in self.handler.monitored_downloads[:]:
			x.abort()
	
	def set_original_implementations(self):
		assert self.original_implementation is None
		self.original_implementation = policy.implementation.copy()

	def versions_changed(self):
		"""Return whether we have now chosen any different implementations.
		If so, we want to show the dialog to the user to confirm the new ones."""
		if not self.ready:
			return True
		if not self.original_implementation:
			return True		# Shouldn't happen?
		if len(self.original_implementation) != len(self.implementation):
			return True
		for iface in self.original_implementation:
			old = self.original_implementation[iface]
			if old is None:
				return True
			new = self.implementation.get(iface, None)
			if new is None:
				return True
			if old.id != new.id:
				return True
		return False

def pretty_size(size):
	if size is None:
		return '?'
	if size < 2048:
		return '%d bytes' % size
	size = float(size)
	for unit in ('Kb', 'Mb', 'Gb', 'Tb'):
		size /= 1024
		if size < 2048:
			break
	return '%.1f %s' % (size, unit)
