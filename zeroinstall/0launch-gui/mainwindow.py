import gtk
from logging import warn
import os, sys
from iface_browser import InterfaceBrowser
import help_box
from gui import policy
from dialog import Dialog, MixedButton

tips = gtk.Tooltips()

SHOW_PREFERENCES = 0

class MainWindow(Dialog):
	progress = None
	browser = None
	download_box = None

	def __init__(self, prog_args, download_only):
		Dialog.__init__(self)
		self.set_title('Zero Install')
		self.set_default_size(gtk.gdk.screen_width() * 2 / 5, 300)

		self.connect('destroy', lambda w: self.destroyed())

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		# Global actions
		hbox = gtk.HBox(False, 0)
		vbox.pack_start(hbox, False, True, 0)
		hbox.set_spacing(4)

		label = gtk.Label(_('Choose the versions to use:'))
		label.set_alignment(0.0, 0.5)
		hbox.pack_start(label, True, True, 0)

		button = MixedButton('_Refresh all now', gtk.STOCK_REFRESH)
		button.connect('clicked', lambda b: policy.refresh_all())
		tips.set_tip(button, _('Check all the interfaces below for updates.'))
		hbox.pack_start(button, False, True, 0)

		cache = MixedButton('_Show Cache', gtk.STOCK_OPEN)
		cache.connect('clicked',
			lambda b: os.spawnlp(os.P_WAIT, sys.argv[0], sys.argv[0], '-c'))
		hbox.pack_start(cache, False, True, 0)

		# Tree view
		self.browser = InterfaceBrowser()
		vbox.pack_start(self.browser, True, True, 0)
		self.browser.show()

		# Interface actions
		hbox = gtk.HBox(False, 0)
		vbox.pack_start(hbox, False, True, 0)
		hbox.set_spacing(4)

		button = gtk.Button('Interface Properties...')
		self.browser.edit_properties.connect_proxy(button)
		hbox.pack_start(button, False, True, 0)
		tips.set_tip(button, _('See and edit the details of the selected interface.'))

		vbox.show_all()

		# Progress bar (hidden by default)
		self.progress = gtk.ProgressBar()
		hbox.pack_start(self.progress, True, True, 0)

		# Responses

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		b = self.add_button(gtk.STOCK_PREFERENCES, SHOW_PREFERENCES)
		self.action_area.set_child_secondary(b, True)

		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		if download_only:
			self.add_mixed_button('_Download', gtk.STOCK_NETWORK, gtk.RESPONSE_OK)
		else:
			self.add_mixed_button('Run', gtk.STOCK_EXECUTE, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)
		self.default_widget.grab_focus()

		def response(dialog, resp):
			import download_box
			if resp in (gtk.RESPONSE_CANCEL, gtk.RESPONSE_DELETE_EVENT):
				self.destroy()
				sys.exit(1)
			elif resp == gtk.RESPONSE_OK:
				download_box.download_with_gui(self,
								prog_args, main = policy.main_exec,
								run_afterwards = not download_only)
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
			elif resp == SHOW_PREFERENCES:
				import preferences
				preferences.show_preferences()
		self.connect('response', response)

		# Warnings
		try:
			version_stream = os.popen('gpg --version')
			gpg_version = map(int, version_stream.readline().split(' ')[-1].strip().split('.'))
			version_stream.close()
		except Exception, ex:
			warn("Failed to get GPG version: %s", ex)
		else:
			if gpg_version < [1, 4, 2, 2]:
				# Don't want about versions < 1.4.6 because Ubuntu fixed it without
				# updating the version number.
				warning_label = gtk.Label("Warning: Your version of gnupg (%s) contains a signature\n"
					"checking vulnerability. Suggest upgrading to 1.4.6 or later." % '.'.join(map(str, gpg_version)))
				vbox.pack_start(warning_label, False, True, 0)
				warning_label.show()
	
	def destroyed(self):
		policy.abort_all_downloads()
		

gui_help = help_box.HelpBox("Injector Help",
('Overview', """
A program is made up of many different components, typically written by different \
groups of people. Each component is available in multiple versions. The injector is \
used when starting a program. Its job is to decide which implementation of each required \
component to use.

An interface describes what a component does. The injector starts with \
the interface for the program you want to run (like 'The Gimp') and chooses an \
implementation (like 'The Gimp 2.2.0'). However, this implementation \
will in turn depend on other interfaces, such as 'GTK' (which draws the menus \
and buttons). Thus, the injector must choose implementations of \
each dependency (each of which may require further interfaces, and so on)."""),

('List of interfaces', """
The main window displays all these interfaces, and the version of each chosen \
implementation. The top-most one represents the program you tried to run, and each direct \
child is a dependency. The 'Fetch' column shows the amount of data that needs to be \
downloaded, or '(cached)' if it is already on this computer.

If you are happy with the choices shown, click on the Download (or Run) button to \
download (and run) the program."""),

('Choosing different versions', """
To control which implementations (versions) are chosen you can click on Preferences \
and adjust the network policy and the overall stability policy. These settings affect \
all programs run using Zero Install.

Alternatively, you can edit the policy of an individual interface by selecting it \
and clicking on the 'Interface Properties' button. \
See that dialog's help text for more information."""),

('The cache', """
Each version of a program that is downloaded is stored in the Zero Install cache. This \
means that it won't need to be downloaded again each time you run the program. Click on \
the 'Show Cache' button to see what is currently in the cache, or to remove versions \
you no longer need to save disk space."""),
)
