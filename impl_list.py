import gtk

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

# Columns
USE = 0
ARCH = 1
STABILITY = 2
VERSION = 3
CACHED = 4
PATH = 5
SIZE = 6
ITEM = 7

class ImplementationList(gtk.ScrolledWindow):
	def __init__(self):
		gtk.ScrolledWindow.__init__(self, None, None)
		self.set_shadow_type(gtk.SHADOW_IN)

		self.model = gtk.ListStore(str, str, str, str, bool, str, str, object)
		self.tree_view = gtk.TreeView(self.model)

		text = gtk.CellRendererText()

		column = gtk.TreeViewColumn('Use', text,
					  text = USE)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Version', text,
					  text = VERSION)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Stability', text,
					  text = STABILITY)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('C', gtk.CellRendererToggle(),
					  active = CACHED)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Arch', text,
					  text = ARCH)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Size', text,
					  text = SIZE)
		self.tree_view.append_column(column)

		column = gtk.TreeViewColumn('Location', text,
					  text = PATH)
		self.tree_view.append_column(column)

		self.add(self.tree_view)
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		for item in items:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][USE] = '-'
			self.model[new][VERSION] = item.get_version()
			self.model[new][CACHED] = item.get_cached()
			self.model[new][STABILITY] = item.get_stability()
			self.model[new][ARCH] = item.arch or 'any'
			self.model[new][PATH] = item.path
			self.model[new][SIZE] = pretty_size(item.size)
	
	def clear(self):
		self.model.clear()

