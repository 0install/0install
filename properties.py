from model import *
import gtk

import help_box
from dialog import Dialog
from policy import policy
from impl_list import ImplementationList
import writer

_dialogs = {}	# Interface -> Properties

def enumerate(items):
	x = 0
	for i in items:
		yield x, i
		x += 1

class Properties(Dialog):
	interface = None
	use_list = None

	def __init__(self, interface):
		Dialog.__init__(self)
		self.interface = interface
		self.set_title('Interface ' + interface.get_name())
		self.set_default_size(gtk.gdk.screen_width() / 2,
				      gtk.gdk.screen_height() / 3)

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_REFRESH, 1)
		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CANCEL)
		self.set_default_response(gtk.RESPONSE_CANCEL)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			elif resp == 1:
				import reader
				reader.update_from_network(interface)
				policy.recalculate()
			elif resp == gtk.RESPONSE_HELP:
				properties_help.display()
		self.connect('response', response)

		swin = gtk.ScrolledWindow(None, None)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		vbox.pack_start(swin, False, True, 0)
		description = gtk.TextView()
		description.set_left_margin(4)
		description.set_right_margin(4)
		description.set_wrap_mode(gtk.WRAP_WORD)
		description.set_editable(False)
		description.set_cursor_visible(False)
		swin.add(description)

		buffer = description.get_buffer()
		heading_style = buffer.create_tag(underline = True, scale = 1.2)
		iter = buffer.get_start_iter()
		buffer.insert_with_tags(iter,
			'%s (%s)' % (interface.get_name(), interface.summary), heading_style)

		buffer.insert(iter, '\nFull name: %s\n\n' % interface.uri)

		buffer.insert_with_tags(iter, 'Description\n', heading_style)

		description.set_size_request(-1, 100)

		buffer.insert(iter, interface.description or "-")

		self.use_list = ImplementationList(interface)
		vbox.pack_start(self.use_list, True, True, 0)
		self.use_list.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)

		hbox = gtk.HBox(False, 2)
		vbox.pack_start(hbox, False, True, 0)

		stability = gtk.combo_box_new_text()
		stability.append_text('Use default setting')
		stability.set_active(0)
		for i, x in enumerate((stable, testing, developer)):
			stability.append_text(str(x).capitalize())
			if x is interface.stability_policy:
				stability.set_active(i + 1)
		hbox.pack_start(gtk.Label('Preferred stability:'), False, True, 0)
		hbox.pack_start(stability, False, True, 0)
		def set_stability_policy(combo):
			i = stability.get_active()
			if i == 0:
				new_stability = None
			else:
				name = stability.get_model()[i][0].lower()
				new_stability = stability_levels[name]
			interface.set_stability_policy(new_stability)
			writer.save_interface(interface)
			policy.recalculate()
		stability.connect('changed', set_stability_policy)

		self.update_list()
		vbox.show_all()

		self.connect('destroy', lambda s: policy.watchers.remove(self.update_list))
		policy.watchers.append(self.update_list)
	
	def update_list(self):
		impls = policy.get_ranked_implementations(self.interface)
		self.use_list.set_items(impls)
	
def edit(interface):
	assert isinstance(interface, Interface)
	if interface in _dialogs:
		_dialogs[interface].destroy()
	_dialogs[interface] = Properties(interface)
	_dialogs[interface].show()

properties_help = help_box.HelpBox("Injector Properties Help",
('Interface properties', """
This window displays information about an interface. At the top is the interface's \
short name, unique ID, summary and long description. The unique ID is also the \
location which is used to update the information."""),

('Implementations', """
The main part of the window is a list of all known implementations of the interface. \
The columns have the following meanings:

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating (overridden values are shown in upper-case). \
You can also use the special level 'preferred'.

C(ached) indicates whether the implementation is already stored on your computer. \
In off-line mode, only cached implementations are considered for use.

Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.

Location is the path that will be used for the implementation when the program is run.
"""),
('Sort order', """
The implementations are listed in the injector's currently preferred order (the one \
at the top will actually be used). Usable implementations all come before unusable \
ones.

Unusable ones are those for incompatible \
architectures, those marked as 'buggy', versions explicitly marked as incompatible with \
another interface you are using and, in off-line mode, uncached implementations. Unusable \
implementations are shown crossed out.

For the usable implementations, the order is as follows:

- Preferred implementations come first.

- Then, if network use is set to 'Minimal', cached implementations come before \
non-cached.

- Then, implementations at or above the selected stability level come before all others.

- Then, higher-numbered versions come before low-numbered ones.

- Then cached come before non-cached (for 'Full' network use mode).
"""))
