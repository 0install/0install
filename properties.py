from model import *
import gtk

import help_box
from dialog import Dialog

_dialogs = {}	# Interface -> Properties

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

class UseList(gtk.ScrolledWindow):
	USE = 0
	ARCH = 1
	STABILITY = 2
	VERSION = 3
	CACHED = 4
	PATH = 5
	SIZE = 6
	ITEM = 7

	def __init__(self):
		gtk.ScrolledWindow.__init__(self, None, None)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.ListStore(str, str, str, str, bool, str, str, object)
		self.tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()

		column = gtk.TreeViewColumn('Use', text,
					  text = UseList.USE)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Version', text,
					  text = UseList.VERSION)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Stability', text,
					  text = UseList.STABILITY)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('C', gtk.CellRendererToggle(),
					  active = UseList.CACHED)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Arch', text,
					  text = UseList.ARCH)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Size', text,
					  text = UseList.SIZE)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Location', text,
					  text = UseList.PATH)
		self.tree_view.append_column(column)

		self.add(self.tree_view)
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		for item in items:
			new = self.model.append()
			self.model[new][UseList.ITEM] = item
			self.model[new][UseList.USE] = '-'
			self.model[new][UseList.VERSION] = item.version
			self.model[new][UseList.CACHED] = item.get_cached()
			self.model[new][UseList.STABILITY] = item.get_stability()
			self.model[new][UseList.ARCH] = item.arch or 'any'
			self.model[new][UseList.PATH] = item.path
			self.model[new][UseList.SIZE] = pretty_size(item.size)
	
	def clear(self):
		self.model.clear()

class Properties(Dialog):
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
		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CANCEL)
		self.set_default_response(gtk.RESPONSE_CANCEL)

		label = gtk.Label('%s: %s' % (interface.get_name(),
						interface.summary))
		vbox.pack_start(label, False, True, 0)

		vbox.pack_start(gtk.Label('(%s)' % interface.uri),
					False, True, 0)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			elif resp == gtk.RESPONSE_HELP:
				properties_help.display()
		self.connect('response', response)

		frame = gtk.Frame()
		frame.set_shadow_type(gtk.SHADOW_IN)
		vbox.pack_start(frame, False, True, 0)
		description = gtk.Label(interface.description)
		description.set_line_wrap(True)
		frame.add(description)

		use_list = UseList()
		impls = interface.implementations.values()
		impls.sort()
		use_list.set_items(impls)
		vbox.pack_start(use_list, True, True, 0)
		use_list.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)

		prefer_stable = gtk.CheckButton('Prefer stable versions')
		vbox.pack_start(prefer_stable, False, True, 0)

		vbox.show_all()
	
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

Use can be 'prefer', if you want to use this implementation in preference to others, \
or 'avoid' if you never want to use it.

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating.

C(ached) indicates whether the implementation is already stored on your computer. \
In off-line mode, only cached implementations are considered for use.

Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.

Location is the path that will be used for the implementation when the program is run.
"""),
('Sort order', """
The implementations are listed in the injector's currently preferred order (the one \
at the top will be actually be used). Usable implementations all come before unusable \
ones.

Unusable ones are those marked as 'avoid', those for incompatible \
architectures, those marked as 'buggy', versions explicitly marked as incompatible with \
another interface you are using and, in off-line mode, uncached implementations. Unusable \
implementations are shown shaded.

For the usable implementations, the order is as follows:

- 'prefer' implementations all come before normal ones.

- If the option to prefer 'stable' implementations is set, 'stable' ones come before \
'testing'.

- Then, higher-numbered versions come before low-numbered ones.

- Then cached come before non-cached.

- The closest compatible architecture is preferred.

- The smallest implementation is preferred.
"""))
