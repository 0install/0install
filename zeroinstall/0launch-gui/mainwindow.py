import gtk
from logging import warn
import os, sys
from zeroinstall.support import tasks
from iface_browser import InterfaceBrowser
import help_box
from gui import policy
import dialog

tips = gtk.Tooltips()

SHOW_PREFERENCES = 0

class MainWindow:
	progress = None
	browser = None
	window = None

	def __init__(self, download_only):
		widgets = policy.widgets

		self.window = widgets.get_widget('main')
		self.window.set_default_size(gtk.gdk.screen_width() * 2 / 5, 300)

		self.progress = widgets.get_widget('progress')

		self.window.connect('destroy', lambda w: self.destroyed())

		cache = widgets.get_widget('show_cache')
		cache.connect('clicked',
			lambda b: os.spawnlp(os.P_WAIT, sys.argv[0], sys.argv[0], '-c'))

		widgets.get_widget('refresh').connect('clicked', lambda b: policy.refresh_all())

		# Tree view
		self.browser = InterfaceBrowser(widgets.get_widget('components'))

		prefs = widgets.get_widget('preferences')
		self.window.action_area.set_child_secondary(prefs, True)

		if download_only:
			unused = widgets.get_widget('run').hide()
		else:
			unused = widgets.get_widget('download').hide()

		self.window.set_default_response(gtk.RESPONSE_OK)
		self.window.default_widget.grab_focus()

		def response(dialog, resp):
			if resp in (gtk.RESPONSE_CANCEL, gtk.RESPONSE_DELETE_EVENT):
				self.window.destroy()
				sys.exit(1)
			elif resp == gtk.RESPONSE_OK:
				task = tasks.Task(self.download_and_run(), "download and run")
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
			elif resp == SHOW_PREFERENCES:
				import preferences
				preferences.show_preferences()
		self.window.connect('response', response)

	def destroy(self):
		self.window.destroy()

	def show(self):
		self.window.show()

	def set_response_sensitive(self, response, sensitive):
		self.window.set_response_sensitive(response, sensitive)

	def destroyed(self):
		policy.abort_all_downloads()

	def download_and_run(self):
		task = tasks.Task(policy.download_impls(), "download implementations")

		yield task.finished
		tasks.check(task.finished)

		if policy.get_uncached_implementations():
			dialog.alert('Not all downloads succeeded; cannot run program.')
		else:
			from zeroinstall.injector import selections
			sels = selections.Selections(policy)
			doc = sels.toDOM()
			reply = doc.toxml('utf-8')
			sys.stdout.write(('Length:%8x\n' % len(reply)) + reply)
			self.window.destroy()
			sys.exit(0)			# Success

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
See that dialog's help text for more information.

Right-click on an interface in the list for a menu.
"""),

('Reporting bugs', """
To report a bug, right-click over the interface which you think contains the problem \
and choose 'Report a Bug...' from the menu. If you don't know which one is the cause, \
choose the top one (i.e. the program itself). The program's author can reassign the \
bug if necessary, or switch to using a different version of the library.
"""),

('The cache', """
Each version of a program that is downloaded is stored in the Zero Install cache. This \
means that it won't need to be downloaded again each time you run the program. Click on \
the 'Show Cache' button to see what is currently in the cache, or to remove versions \
you no longer need to save disk space."""),
)
