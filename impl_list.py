import gtk
import model
from gui import policy
import writer

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

def popup_menu(bev, values, fn):
	menu = gtk.Menu()
	for value in values:
		if value is None:
			item = gtk.SeparatorMenuItem()
		else:
			item = gtk.MenuItem(str(value).capitalize())
			item.connect('activate', lambda item, v=value: fn(v))
		item.show()
		menu.append(item)
	menu.popup(None, None, None, bev.button, bev.time)

# Columns
ITEM = 0
ARCH = 1
STABILITY = 2
VERSION = 3
CACHED = 4
ID = 5
SIZE = 6
UNUSABLE = 7

class ImplementationList(gtk.ScrolledWindow):
	tree_view = None
	model = None

	def __init__(self, interface):
		gtk.ScrolledWindow.__init__(self, None, None)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.ListStore(object, str, str, str, bool, str, str, bool)
		self.tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()
		text_strike = gtk.CellRendererText()
		toggle = gtk.CellRendererToggle()

		stability = gtk.TreeViewColumn('Stability', text, text = STABILITY)

		for column in (gtk.TreeViewColumn('Version', text, text = VERSION),
			       stability,
			       gtk.TreeViewColumn('C', toggle, active = CACHED),
			       gtk.TreeViewColumn('Arch', text, text = ARCH),
			       gtk.TreeViewColumn('Size', text, text = SIZE),
			       gtk.TreeViewColumn('ID', text_strike, text = ID,
			       				strikethrough = UNUSABLE)):
			self.tree_view.append_column(column)

		self.add(self.tree_view)

		def button_press(tree_view, bev):
			if bev.button not in (1, 3):
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			if col == stability:
				impl = self.model[path][ITEM]
				upstream = impl.upstream_stability or model.testing
				choices = model.stability_levels.values()
				choices.sort()
				choices.reverse()
				def set(new):
					if isinstance(new, model.Stability):
						impl.user_stability = new
					else:
						impl.user_stability = None
					writer.save_interface(interface)
					policy.recalculate()
				popup_menu(bev, ['Unset (%s)' % upstream, None] + choices,
					set)
		self.tree_view.connect('button-press-event', button_press)
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		for item in items:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][VERSION] = item.get_version()
			self.model[new][CACHED] = policy.get_cached(item)
			if item.user_stability:
				self.model[new][STABILITY] = str(item.user_stability).upper()
			else:
				self.model[new][STABILITY] = item.upstream_stability or \
							     model.testing
			self.model[new][ARCH] = item.arch or 'any'
			self.model[new][ID] = item.id
			self.model[new][SIZE] = pretty_size(item.size)
			self.model[new][UNUSABLE] = policy.is_unusable(item)
	
	def clear(self):
		self.model.clear()

