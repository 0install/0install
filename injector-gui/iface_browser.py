import gtk

from model import Interface
import properties
import reader
from policy import policy

class InterfaceBrowser(gtk.ScrolledWindow):
	model = None
	root = None
	edit_properties = None

	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	SUMMARY = 3

	def __init__(self, root):
		assert isinstance(root, Interface)
		self.root = root
		self.edit_properties = gtk.Action('edit_properties',
			  'Interface Properties...',
			  'Set which implementation of this interface to use.',
			  gtk.STOCK_PROPERTIES)
		self.edit_properties.set_property('sensitive', False)

		gtk.ScrolledWindow.__init__(self)
		self.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.TreeStore(object, str, str, str)
		self.tree_view = tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()

		column = gtk.TreeViewColumn(_('Interface'), text,
					  text = InterfaceBrowser.INTERFACE_NAME)
		tree_view.append_column(column)

		column = gtk.TreeViewColumn(_('Version'), text,
					  text = InterfaceBrowser.VERSION)
		tree_view.append_column(column)

		column = gtk.TreeViewColumn(_('Description'), text,
					  text = InterfaceBrowser.SUMMARY)
		tree_view.append_column(column)

		self.add(tree_view)
		tree_view.show()

		tree_view.set_enable_search(True)

		selection = tree_view.get_selection()

		def sel_changed(sel):
			store, iter = sel.get_selected()
			self.edit_properties.set_property('sensitive', iter != None)
		selection.connect('changed', sel_changed)

		def button_press(tree_view, bev):
			if bev.button != 1 or bev.type != gtk.gdk._2BUTTON_PRESS:
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			properties.edit(self.model[path][InterfaceBrowser.INTERFACE])
		tree_view.connect('button-press-event', button_press)

		def edit_selected(action):
			store, iter = selection.get_selected()
			assert iter
			properties.edit(self.model[iter][InterfaceBrowser.INTERFACE])
		self.edit_properties.connect('activate', edit_selected)

		self.connect('destroy', lambda s: policy.watchers.remove(self.build_tree))
		policy.watchers.append(self.build_tree)

		policy.recalculate()

	def build_tree(self):
		self.model.clear()
		parent = None
		def add_node(parent, iface):
			iter = self.model.append(parent)
			self.model[iter][InterfaceBrowser.INTERFACE] = iface
			self.model[iter][InterfaceBrowser.INTERFACE_NAME] = iface.get_name()
			self.model[iter][InterfaceBrowser.SUMMARY] = iface.summary

			impl = policy.implementation.get(iface, None)
			if impl:
				self.model[iter][InterfaceBrowser.VERSION] = impl.get_version()
				for child in impl.dependencies.values():
					add_node(iter, child.get_interface())
			else:
				self.model[iter][InterfaceBrowser.VERSION] = '(choose)'
		add_node(None, self.root)
		self.tree_view.expand_all()
