import gtk
from iface_browser import InterfaceBrowser
import help_box
from dialog import Dialog

gtk.rc_parse_string('style "scrolled" { '
		    'GtkScrolledWindow::scrollbar-spacing = 0}\n'
		    'class "GtkScrolledWindow" style : gtk "scrolled"\n')

class MainWindow(Dialog):
	def __init__(self, root_interface):
		Dialog.__init__(self)
		self.set_title('Dependency Injector')
		self.set_default_size(400, 300)

		label = gtk.Label('Need to download interface definitions...')
		self.vbox.pack_start(label, False, True, 0)
		label.set_padding(8, 8)
		label.show()

		browser = InterfaceBrowser(root_interface)
		self.vbox.pack_start(browser, True, True, 0)
		browser.show()

		hbox = gtk.HBox(False, 2)
		self.vbox.pack_start(hbox, False, True, 0)

		network = gtk.combo_box_new_text()
		network.append_text('Off-line')
		network.append_text('Minimal')
		network.append_text('Full')
		network.set_active(1)
		hbox.pack_start(gtk.Label('Network use:'), False, True, 0)
		hbox.pack_start(network, False, True, 0)

		hbox.pack_start(gtk.EventBox(), True, True, 0)

		button = gtk.Button()
		browser.edit_properties.connect_proxy(button)
		hbox.pack_start(button, False, True, 0)
		hbox.set_border_width(4)
		hbox.show_all()

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_EXECUTE, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			elif resp == gtk.RESPONSE_OK:
				self.destroy()
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
		self.connect('response', response)

gui_help = help_box.HelpBox("Injector Help",
('Overview', """
A program is made up of many different components, typically written by different \
groups of people. Each component is available in multiple versions. The injector is \
used when starting a program. Its job is to decide which version of each required \
component to use.

An interface describes what a component does. The injector starts with \
the interface for the program you want to run (like 'The Gimp') and chooses an \
implementation (like 'The Gimp 2.2.0').  However, this implementation \
will in turn depend on other interfaces, such as 'GTK' (which draws the menus \
and buttons, for example).  Thus, the injector must choose implementations of \
each dependancy (each of which may require further interfaces, and so on)."""),

('The main window', """
The main window displays all these interfaces, and the chosen version of each
one. The top-most one represents the program you tried to run, and each direct
child is a dependancy of the version chosen.

If you are happy with the versions shown, click on the Execute button to run the \
program.

If you want to try a different version of some interface, click on it to \
open the properties box for that interface."""))
