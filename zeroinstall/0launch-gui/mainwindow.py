# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
import sys
from logging import info, warn

from zeroinstall import _, translation
from zeroinstall import SafeException
from zeroinstall.support import tasks, pretty_size
from zeroinstall.injector import download, iface_cache
from iface_browser import InterfaceBrowser
import dialog
from zeroinstall.gtkui import gtkutils
from zeroinstall.gtkui import help_box

ngettext = translation.ngettext

SHOW_PREFERENCES = 0

class MainWindow(object):
	progress = None
	progress_area = None
	browser = None
	window = None
	cancel_download_and_run = None
	driver = None
	comment = None
	systray_icon = None
	systray_icon_blocker = None

	def __init__(self, driver, widgets, download_only, select_only = False):
		self.driver = driver
		self.select_only = select_only

		def update_ok_state():
			self.window.set_response_sensitive(gtk.RESPONSE_OK, driver.solver.ready)
			if driver.solver.ready and self.window.get_focus() is None:
				run_button.grab_focus()
		driver.watchers.append(update_ok_state)

		self.window = widgets.get_widget('main')
		self.window.set_default_size(gtk.gdk.screen_width() * 2 / 5, 300)

		self.progress = widgets.get_widget('progress')
		self.progress_area = widgets.get_widget('progress_area')
		self.comment = widgets.get_widget('comment')

		widgets.get_widget('stop').connect('clicked', lambda b: driver.config.handler.abort_all_downloads())

		self.refresh_button = widgets.get_widget('refresh')

		# Tree view
		self.browser = InterfaceBrowser(driver, widgets)

		prefs = widgets.get_widget('preferences')
		self.window.get_action_area().set_child_secondary(prefs, True)

		# Glade won't let me add this to the template!
		if select_only:
			run_button = dialog.MixedButton(_("_Select"), gtk.STOCK_EXECUTE, button = gtk.ToggleButton())
		elif download_only:
			run_button = dialog.MixedButton(_("_Download"), gtk.STOCK_EXECUTE, button = gtk.ToggleButton())
		else:
			run_button = dialog.MixedButton(_("_Run"), gtk.STOCK_EXECUTE, button = gtk.ToggleButton())
		self.window.add_action_widget(run_button, gtk.RESPONSE_OK)
		run_button.show_all()
		if gtk.pygtk_version >= (2,22,0):
			run_button.set_can_default(True)
		else:
			run_button.set_flags(gtk.CAN_DEFAULT)
		self.run_button = run_button

		run_button.grab_focus()

		def response(dialog, resp):
			if resp in (gtk.RESPONSE_CANCEL, gtk.RESPONSE_DELETE_EVENT):
				self.window.destroy()
				sys.exit(1)
			elif resp == gtk.RESPONSE_OK:
				if self.cancel_download_and_run:
					self.cancel_download_and_run.trigger()
				if run_button.get_active():
					self.cancel_download_and_run = tasks.Blocker("cancel downloads")
					self.download_and_run(run_button, self.cancel_download_and_run)
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
			elif resp == SHOW_PREFERENCES:
				import preferences
				preferences.show_preferences(driver.config, notify_cb = lambda: driver.solve_with_downloads())
		self.window.connect('response', response)
		self.window.realize()	# Make busy pointer work, even with --systray

	def destroy(self):
		self.window.destroy()

	def show(self):
		self.window.show()

	def set_response_sensitive(self, response, sensitive):
		self.window.set_response_sensitive(response, sensitive)

	@tasks.async
	def download_and_run(self, run_button, cancelled):
		try:
			if not self.select_only:
				downloaded = self.driver.download_uncached_implementations()

				if downloaded:
					# We need to wait until everything is downloaded...
					blockers = [downloaded, cancelled]
					yield blockers
					tasks.check(blockers)

					if cancelled.happened:
						return

				uncached = self.driver.get_uncached_implementations()
			else:
				uncached = None		# (we don't care)

			if uncached:
				missing = '\n- '.join([_('%(iface_name)s %(impl_version)s') % {'iface_name': iface.get_name(), 'impl_version': impl.get_version()} for iface, impl in uncached])
				dialog.alert(self.window, _('Not all downloads succeeded; cannot run program.\n\nFailed to get:') + '\n- ' + missing)
			else:
				sels = self.driver.solver.selections
				doc = sels.toDOM()
				reply = doc.toxml('utf-8')
				if sys.version_info[0] > 2:
					stdout = sys.stdout.buffer
				else:
					stdout = sys.stdout
				stdout.write(('Length:%8x\n' % len(reply)).encode('utf-8') + reply)
				self.window.destroy()
				sys.exit(0)			# Success
		except SystemExit:
			raise
		except download.DownloadAborted as ex:
			run_button.set_active(False)
			# Don't bother reporting this to the user
		except Exception as ex:
			run_button.set_active(False)
			self.report_exception(ex)

	def update_download_status(self, only_update_visible = False):
		"""Called at regular intervals while there are downloads in progress,
		and once at the end. Update the display."""
		monitored_downloads = self.driver.config.handler.monitored_downloads

		self.browser.update_download_status(only_update_visible)

		if not monitored_downloads:
			self.progress_area.hide()
			self.window.get_window().set_cursor(None)
			return

		if not self.progress_area.get_property('visible'):
			self.progress_area.show()
			self.window.get_window().set_cursor(gtkutils.get_busy_pointer())

		any_known = False
		done = total = self.driver.config.handler.total_bytes_downloaded	# Completed downloads
		n_downloads = self.driver.config.handler.n_completed_downloads
		# Now add downloads in progress...
		for x in monitored_downloads:
			if x.status != download.download_fetching: continue
			n_downloads += 1
			if x.expected_size:
				any_known = True
			so_far = x.get_bytes_downloaded_so_far()
			total += x.expected_size or max(4096, so_far)	# Guess about 4K for feeds/icons
			done += so_far

		progress_text = '%s / %s' % (pretty_size(done), pretty_size(total))
		self.progress.set_text(
			ngettext('Downloading one file (%(progress)s)',
					 'Downloading %(number)d files (%(progress)s)', n_downloads)
			% {'progress': progress_text, 'number': n_downloads})

		if total == 0 or (n_downloads < 2 and not any_known):
			self.progress.pulse()
		else:
			self.progress.set_fraction(float(done) / total)

	def set_message(self, message):
		import pango
		self.comment.set_text(message)
		attrs = pango.AttrList()
		attrs.insert(pango.AttrWeight(pango.WEIGHT_BOLD, end_index = len(message)))
		self.comment.set_attributes(attrs)
		self.comment.show()

	def use_systray_icon(self):
		try:
			if sys.version_info[0] > 2:
				self.systray_icon = gtk.StatusIcon.new_from_icon_name("zeroinstall")
			else:
				self.systray_icon = gtk.status_icon_new_from_icon_name("zeroinstall")
		except Exception as ex:
			info(_("No system tray support: %s"), ex)
		else:
			root_iface = iface_cache.iface_cache.get_interface(self.driver.requirements.interface_uri)
			self.systray_icon.set_tooltip(_('Checking for updates for %s') % root_iface.get_name())
			self.systray_icon.connect('activate', self.remove_systray_icon)
			self.systray_icon_blocker = tasks.Blocker('Tray icon clicked')

	def remove_systray_icon(self, i = None):
		assert self.systray_icon, i
		self.show()
		self.systray_icon.set_visible(False)
		self.systray_icon = None
		self.systray_icon_blocker.trigger()
		self.systray_icon_blocker = None

	def report_exception(self, ex, tb = None):
		if not isinstance(ex, SafeException):
			if tb is None:
				warn(ex, exc_info = True)
			else:
				warn(ex, exc_info = (type(ex), ex, tb))
			if isinstance(ex, AssertionError):
				# Assertions often don't say that they're errors (and are frequently
				# blank).
				ex = repr(ex)
		if self.systray_icon:
			if hasattr(self.systray_icon, 'set_blinking'):
				self.systray_icon.set_blinking(True)
			self.systray_icon.set_tooltip(str(ex) + '\n' + _('(click for details)'))
		else:
			dialog.alert(self.window, str(ex) or repr(ex))

gui_help = help_box.HelpBox(_("Injector Help"),
(_('Overview'), '\n' +
_("""A program is made up of many different components, typically written by different \
groups of people. Each component is available in multiple versions. Zero Install is \
used when starting a program. Its job is to decide which implementation of each required \
component to use.

Zero Install starts with the program you want to run (like 'The Gimp') and chooses an \
implementation (like 'The Gimp 2.2.0'). However, this implementation \
will in turn depend on other components, such as 'GTK' (which draws the menus \
and buttons). Thus, it must choose implementations of \
each dependency (each of which may require further components, and so on).""")),

(_('List of components'), '\n' +
_("""The main window displays all these components, and the version of each chosen \
implementation. The top-most one represents the program you tried to run, and each direct \
child is a dependency. The 'Fetch' column shows the amount of data that needs to be \
downloaded, or '(cached)' if it is already on this computer.

If you are happy with the choices shown, click on the Download (or Run) button to \
download (and run) the program.""")),

(_('Choosing different versions'), '\n' +
_("""To control which implementations (versions) are chosen you can click on Preferences \
and adjust the network policy and the overall stability policy. These settings affect \
all programs run using Zero Install.

Alternatively, you can edit the policy of an individual component by clicking on the \
button at the end of its line in the table and choosing "Show Versions" from the menu. \
See that dialog's help text for more information.""") + '\n'),

(_('Reporting bugs'), '\n' +
_("""To report a bug, right-click over the component which you think contains the problem \
and choose 'Report a Bug...' from the menu. If you don't know which one is the cause, \
choose the top one (i.e. the program itself). The program's author can reassign the \
bug if necessary, or switch to using a different version of the library.""") + '\n'),

(_('The cache'), '\n' +
_("""Each version of a program that is downloaded is stored in the Zero Install cache. This \
means that it won't need to be downloaded again each time you run the program. The \
"0store manage" command can be used to view the cache.""") + '\n'),
)
