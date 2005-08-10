import gtk

from zeroinstall.injector.model import Interface
import properties
from treetips import TreeTips
from gui import policy, pretty_size

def _stability(impl):
	assert impl
	if impl.user_stability is None:
		return impl.upstream_stability
	return _("%s (was %s)") % (impl.user_stability, impl.upstream_stability)

class InterfaceTips(TreeTips):
	def get_tooltip_text(self, item):
		interface, model_column = item
		assert interface
		if model_column == InterfaceBrowser.INTERFACE_NAME:
			return _("Full name: %s") % interface.uri
		elif model_column == InterfaceBrowser.SUMMARY:
			if not interface.description:
				return None
			first_para = interface.description.split('\n\n', 1)[0]
			return first_para.replace('\n', ' ')

		impl = policy.implementation.get(interface, None)
		if not impl:
			return _("No suitable implementation was found. Check the "
				 "interface properties to find out why.")

		if model_column == InterfaceBrowser.VERSION:
			text = _("Currently preferred version: %s (%s)") % \
					(impl.get_version(), _stability(impl))
			old_impl = policy.original_implementation.get(interface, None)
			if old_impl is not None and old_impl is not impl:
				text += _('\nPreviously preferred version: %s (%s)') % \
					(old_impl.get_version(), _stability(old_impl))
			return text

		assert model_column == InterfaceBrowser.DOWNLOAD_SIZE

		if policy.get_cached(impl):
			return _("This version is already stored on your computer.")
		else:
			src = policy.get_best_source(impl)
			return _("Need to download %s (%s bytes)") % \
					(pretty_size(src.size), src.size)

tips = InterfaceTips()

class InterfaceBrowser(gtk.ScrolledWindow):
	model = None
	root = None
	edit_properties = None

	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	SUMMARY = 3
	DOWNLOAD_SIZE = 4

	columns = [(_('Interface'), INTERFACE_NAME),
		   (_('Version'), VERSION),
		   (_('Fetch'), DOWNLOAD_SIZE),
		   (_('Description'), SUMMARY)]

	def __init__(self):
		self.edit_properties = gtk.Action('edit_properties',
			  'Interface Properties...',
			  'Set which implementation of this interface to use.',
			  gtk.STOCK_PROPERTIES)
		self.edit_properties.set_property('sensitive', False)

		gtk.ScrolledWindow.__init__(self)
		self.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.TreeStore(object, str, str, str, str)
		self.tree_view = tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()

		column_objects = []
		for name, model_column in self.columns:
			column = gtk.TreeViewColumn(name, text, text = model_column)
			tree_view.append_column(column)
			column_objects.append(column)

		self.add(tree_view)
		tree_view.show()

		tree_view.set_enable_search(True)

		selection = tree_view.get_selection()

		def motion(tree_view, ev):
			if ev.window is not tree_view.get_bin_window():
				return False
			pos = tree_view.get_path_at_pos(int(ev.x), int(ev.y))
			if pos:
				path = pos[0]
				col = self.columns[column_objects.index(pos[1])][1]
				row = self.model[path]
				tips.prime(tree_view, (row[InterfaceBrowser.INTERFACE], col))
			else:
				tips.hide()

		tree_view.connect('motion-notify-event', motion)
		tree_view.connect('leave-notify-event', lambda tv, ev: tips.hide())

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

	def set_root(self, root):
		assert isinstance(root, Interface)
		self.root = root
		policy.recalculate()	# Calls build_tree

	def build_tree(self):
		if policy.original_implementation is None:
			policy.set_original_implementations()

		self.model.clear()
		parent = None
		def add_node(parent, iface):
			iter = self.model.append(parent)
			self.model[iter][InterfaceBrowser.INTERFACE] = iface
			self.model[iter][InterfaceBrowser.INTERFACE_NAME] = iface.get_name()
			self.model[iter][InterfaceBrowser.SUMMARY] = iface.summary

			impl = policy.implementation.get(iface, None)
			if impl:
				old_impl = policy.original_implementation.get(iface, None)
				version_str = impl.get_version()
				if old_impl is not None and old_impl is not impl:
					version_str += " (was " + old_impl.get_version() + ")"
				self.model[iter][InterfaceBrowser.VERSION] = version_str

				if policy.get_cached(impl):
					fetch = '(cached)'
				else:
					src = policy.get_best_source(impl)
					fetch = pretty_size(src.size)
				self.model[iter][InterfaceBrowser.DOWNLOAD_SIZE] = fetch
				for child in impl.dependencies.values():
					add_node(iter, policy.get_interface(child.interface))
			else:
				self.model[iter][InterfaceBrowser.VERSION] = '(choose)'
		add_node(None, self.root)
		self.tree_view.expand_all()
