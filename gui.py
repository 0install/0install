import gtk
from iface_browser import InterfaceBrowser
import help_box
from dialog import Dialog
from policy import policy
from model import stable, testing, network_levels, SafeException

gtk.rc_parse_string('style "scrolled" { '
		    'GtkScrolledWindow::scrollbar-spacing = 0}\n'
		    'class "GtkScrolledWindow" style : gtk "scrolled"\n')

class MainWindow(Dialog):
	def __init__(self, prog, prog_args):
		Dialog.__init__(self)
		self.set_title('Dependency Injector')
		self.set_default_size(400, 300)

		tips = gtk.Tooltips()

		# Message
		#label = gtk.Label('Need to download interface definitions...')
		#self.vbox.pack_start(label, False, True, 0)
		#label.set_padding(8, 8)
		#label.show()

		# Network use
		hbox = gtk.HBox(False, 2)
		self.vbox.pack_start(hbox, False, True, 0)
		hbox.set_border_width(4)

		network = gtk.combo_box_new_text()
		for level in network_levels:
			network.append_text(level.capitalize())
		network.set_active(list(network_levels).index(policy.network_use))
		hbox.pack_start(gtk.Label('Network use:'), False, True, 0)
		hbox.pack_start(network, False, True, 2)
		def set_network_use(combo):
			policy.network_use = network_levels[network.get_active()]
			policy.save_config()
			policy.recalculate()
		network.connect('changed', set_network_use)

		hbox.show_all()

		# Tree view
		browser = InterfaceBrowser(policy.get_interface(policy.root))
		self.vbox.pack_start(browser, True, True, 0)
		browser.show()

		# Select versions
		hbox = gtk.HBox(False, 2)
		self.vbox.pack_start(hbox, False, True, 0)
		hbox.set_border_width(4)

		button = gtk.Button()
		browser.edit_properties.connect_proxy(button)
		hbox.pack_start(button, False, True, 0)

		stable_toggle = gtk.CheckButton('Help test new versions')
		hbox.pack_start(stable_toggle, False, True, 0)
		tips.set_tip(stable_toggle,
			"Try out new versions as soon as they are available, instead of "
			"waiting for them to be marked as 'stable'. "
			"This sets the default policy. Click on 'Interface Properties...' "
			"to set the policy for an individual interface.")
		stable_toggle.set_active(policy.help_with_testing)
		def toggle_stability(toggle):
			policy.help_with_testing = toggle.get_active()
			policy.save_config()
			policy.recalculate()
		stable_toggle.connect('toggled', toggle_stability)

		hbox.show_all()

		# Responses

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_EXECUTE, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			elif resp == gtk.RESPONSE_OK:
				import run
				try:
					run.execute(prog, prog_args)
					self.destroy()
				except SafeException, ex:
					box = gtk.MessageDialog(self, gtk.DIALOG_MODAL,
							gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
							str(ex))
					box.run()
					box.destroy()
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
		self.connect('response', response)

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
each dependancy (each of which may require further interfaces, and so on)."""),

('List of interfaces', """
The main window displays all these interfaces, and the version of each chosen \
implementation. The top-most one represents the program you tried to run, and each direct \
child is a dependancy.

If you are happy with the choices shown, click on the Execute button to run the \
program."""),

('Choosing different versions', """
There are three ways to control which implementations are chosen. You can adjust the \
network policy and the overall stability policy, which affect all interfaces, or you \
can edit the policy of individual interfaces.

The 'Network use' option controls how the injector uses the network. If off-line, \
the network is not used at all. If 'Minimal' is selected then the injector will use \
the network if needed, but only if it has no choice. It will run an out-of-date \
version rather than download a newer one. If 'Full' is selected, the injector won't \
worry about how much it downloads, but will always pick the version it thinks is best.

The overall stability policy can either be to prefer stable versions, or to help test \
new versions. Choose whichever suits you. Since different programmers have different \
ideas of what 'stable' means, you may wish to override this on a per-interface basis \
(see below).

To set the policy for an interface individually, select it and click on 'Interface \
Properties'. See that dialog's help text for more information."""))
