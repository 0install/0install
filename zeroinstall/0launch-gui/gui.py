import gtk, os, gobject, sys
import gtk.glade

from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector.policy import Policy
from zeroinstall.injector import download, handler
from zeroinstall.injector.model import SafeException
from zeroinstall.injector.reader import InvalidInterface
from zeroinstall.support import tasks
import dialog
from checking import CheckingBox

version = '0.31'

# Singleton Policy
policy = None

gladefile = os.path.join(os.path.dirname(__file__), 'zero-install.glade')

# Wrapped for glade widget tree that throws a sensible exception if the widget isn't found
class Template:
	def __init__(self, root):
		self.widgets = gtk.glade.XML(gladefile, root)
		self.root = root
	
	def get_widget(self, name = None):
		if not name:
			name = self.root
		widget = self.widgets.get_widget(name)
		assert widget, "Widget '%s' not found in glade file '%s'" % (name, gladefile)
		return widget

class GUIHandler(handler.Handler):
	monitored_downloads = None
	dl_callbacks = None		# Download -> [ callback ]
	pulse = None
	policy = None

	def __init__(self, policy):
		handler.Handler.__init__(self)
		self.policy = policy

	def downloads_changed(self):
		if self.monitored_downloads and self.pulse is None:
			def pulse():
				if self.policy.checking:
					self.policy.checking.progress.pulse()
				else:
					self.policy.window.progress.pulse()
				return True
			self.pulse = gobject.timeout_add(50, pulse)
			self.policy.window.progress.show()
		elif len(self.monitored_downloads) == 0:
			if self.pulse:
				gobject.source_remove(self.pulse)
				self.policy.window.progress.hide()
				self.pulse = None
				
			if self.policy.checking:
				self.policy.checking.updates_done(self.policy.versions_changed())

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		return trust_box.confirm_trust(interface, sigs, iface_xml, parent = self.policy.checking or self.policy.window.window)
	
	def report_error(self, ex):
		dialog.alert(None, str(ex))

class GUIPolicy(Policy):
	window = None
	checking = None		# GtkDialog ("Checking for updates...")
	original_implementation = None
	download_only = None
	widgets = None		# Glade

	def __init__(self, interface, download_only, refresh, src = False, restrictions = None):
		Policy.__init__(self, interface, GUIHandler(self), src = src)
		self.solver.record_details = True
		global policy
		assert policy is None
		policy = self

		self.widgets = Template('main')

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

		self.watchers.append(self.update_display)
	
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
	
	def update_display(self):
		self.window.set_response_sensitive(gtk.RESPONSE_OK, self.ready)

	def main(self):
		solved = tasks.Task(self.solve_with_downloads(), "solve")

		if self.checking:
			self.checking.show()

			yield solved.finished

			self.checking.updates_done(self.versions_changed())

			#dialog.wait_for_no_windows()

			show_details = self.show_details()
			self.checking = None
			if show_details:
				self.window.show()
				yield []
			else:
				raise Exception("STOP")
				import download_box
				download_box.download_with_gui(self.window)
				yield []
		else:
			self.window.show()
			yield []
	
	def abort_all_downloads(self):
		for dl in self.handler.monitored_downloads.values():
			dl.abort()
	
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
