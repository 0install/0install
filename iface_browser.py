import gtk

from model import Interface
from policy import Policy
import properties
import iface_reader

def _(x): return x

class InterfaceBrowser(gtk.ScrolledWindow):
	model = None
	root = None

	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	SUMMARY = 3

	def __init__(self, root):
		assert isinstance(root, Interface)
		self.root = root

		gtk.ScrolledWindow.__init__(self)
		self.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.TreeStore(object, str, str, str)
		tree_view = gtk.TreeView(self.model)

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

		selection = tree_view.get_selection()
		selection.set_mode(gtk.SELECTION_NONE)

		def button_press(tree_view, bev):
			if bev.button != 1:
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			properties.edit(self.model[path][InterfaceBrowser.INTERFACE])

		tree_view.connect('button-press-event', button_press)

		self.build_tree()

		properties.edit(root)
	
	def build_tree(self):
		self.model.clear()
		parent = None
		policy = Policy(self.root)
		def add_node(parent, iface):
			if not iface.uptodate:
				iface_reader.update(iface)
			
			iter = self.model.append(parent)
			self.model[iter][InterfaceBrowser.INTERFACE] = iface
			self.model[iter][InterfaceBrowser.INTERFACE_NAME] = iface.get_name()
			self.model[iter][InterfaceBrowser.SUMMARY] = iface.summary

			impl = policy.get_implementation(iface)
			if impl:
				self.model[iter][InterfaceBrowser.VERSION] = impl.get_version()
				for child in impl.dependencies.values():
					add_node(iter, child.get_interface())
			else:
				self.model[iter][InterfaceBrowser.VERSION] = '(choose)'
		add_node(None, self.root)
