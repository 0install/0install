from model import *
import gtk

import help_box
from dialog import Dialog

_dialogs = {}	# Interface -> Properties

class UseList(gtk.ScrolledWindow):
	USE = 0
	ARCH = 1
	STABILITY = 2
	NAME = 3
	CACHE = 4
	ITEM = 5

	def __init__(self, title, impl = False):
		gtk.ScrolledWindow.__init__(self, None, None)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.ListStore(str, str, str, str, str, object)
		self.tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()

		column = gtk.TreeViewColumn('Use', text,
					  text = UseList.USE)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Stability', text,
					  text = UseList.STABILITY)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Cache', text,
					  text = UseList.CACHE)
		self.tree_view.append_column(column)

		if impl:
			column = gtk.TreeViewColumn('Arch', text,
						  text = UseList.ARCH)
			self.tree_view.append_column(column)

		column = gtk.TreeViewColumn(title, text,
					  text = UseList.NAME)
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
			self.model[new][UseList.NAME] = str(item)
			if item.get_cached():
				self.model[new][UseList.CACHE] = 'cached'
			else:
				self.model[new][UseList.CACHE] = 'no'
			self.model[new][UseList.STABILITY] = item.get_stability()

			if hasattr(item, 'arch'):
				self.model[new][UseList.ARCH] = item.arch or 'any'
	
	def clear(self):
		self.model.clear()

class Properties(Dialog):
	def __init__(self, interface):
		Dialog.__init__(self)
		self.interface = interface
		self.set_title('Interface ' + interface.get_name())
		self.set_default_size(600, 400)

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

		use_list = UseList('Version')
		versions = interface.versions.values()
		versions.sort()
		use_list.set_items(versions)
		vbox.pack_start(use_list, True, True, 0)
		use_list.set_policy(gtk.POLICY_NEVER, gtk.POLICY_ALWAYS)

		def version_changed(selection):
			store, itr = selection.get_selected()
			if itr:
				version = store[itr][UseList.ITEM]
				impls = version.implementations.values()
				impl_list.set_items(impls)
			else:
				impl_list.clear()
		use_list.get_selection().connect('changed', version_changed)

		impl_list = UseList('Implementation', True)
		vbox.pack_start(impl_list, False, True, 0)
		impl_list.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_AUTOMATIC)

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

('Versions', """
In the middle of the window is a list of all known versions of the interface.

The columns have the following meanings:

Use can be 'prefer', if you want to use this implementation in preference to others, \
or 'avoid' if you never want to use it.

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Stability and Cached are described below. Here, they show the details of the \
preferred implementation of each version. Use the section below to set which \
implementation of each version is preferred."""),

('Implementations', """
When a version is selected, a list of implementations of that version are shown \
below (typically, there is only one implementation of each version).

Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.

Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating.

Cached indicates whether the implementation is already stored on your computer.

In off-line mode, only cached implementations are considered for use.

Implementation gives the location.
"""))
