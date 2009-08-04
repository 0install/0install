"""Display the contents of the implementation cache."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os
import gtk

from zeroinstall.injector import namespaces, model
from zeroinstall.zerostore import BadDigest, manifest
from zeroinstall import support
from zeroinstall.support import basedir
from zeroinstall.gtkui.treetips import TreeTips
from zeroinstall.gtkui import help_box, gtkutils

__all__ = ['CacheExplorer']

ROX_IFACE = 'http://rox.sourceforge.net/2005/interfaces/ROX-Filer'

# Model columns
ITEM = 0
SELF_SIZE = 1
PRETTY_SIZE = 2
TOOLTIP = 3
ITEM_OBJECT = 4

def popup_menu(bev, obj):
	menu = gtk.Menu()
	for i in obj.menu_items:
		if i is None:
			item = gtk.SeparatorMenuItem()
		else:
			name, cb = i
			item = gtk.MenuItem(name)
			item.connect('activate', lambda item, cb=cb: cb(obj))
		item.show()
		menu.append(item)
	menu.popup(None, None, None, bev.button, bev.time)

def size_if_exists(path):
	"Get the size for a file, or 0 if it doesn't exist."
	if path and os.path.isfile(path):
		return os.path.getsize(path)
	return 0

def get_size(path):
	"Get the size for a directory tree. Get the size from the .manifest if possible."
	man = os.path.join(path, '.manifest')
	if os.path.exists(man):
		size = os.path.getsize(man)
		for line in file(man):
			if line[:1] in "XF":
				size += long(line.split(' ', 4)[3])
	else:
		size = 0
		for root, dirs, files in os.walk(path):
			for name in files:
				size += os.path.getsize(os.path.join(root, name))
	return size

def summary(iface):
	if iface.summary:
		return iface.get_name() + ' - ' + iface.summary
	return iface.get_name()

def get_selected_paths(tree_view):
	"GTK 2.0 doesn't have this built-in"
	selection = tree_view.get_selection()
	paths = []
	def add(model, path, iter):
		paths.append(path)
	selection.selected_foreach(add)
	return paths

tips = TreeTips()

# Responses
DELETE = 0

class CachedInterface(object):
	def __init__(self, uri, size):
		self.uri = uri
		self.size = size

	def delete(self):
		if not self.uri.startswith('/'):
			cached_iface = basedir.load_first_cache(namespaces.config_site,
					'interfaces', model.escape(self.uri))
			if cached_iface:
				#print "Delete", cached_iface
				os.unlink(cached_iface)
		user_overrides = basedir.load_first_config(namespaces.config_site,
					namespaces.config_prog,
					'user_overrides', model.escape(self.uri))
		if user_overrides:
			#print "Delete", user_overrides
			os.unlink(user_overrides)
	
	def __cmp__(self, other):
		return self.uri.__cmp__(other.uri)

class ValidInterface(CachedInterface):
	def __init__(self, iface, size):
		CachedInterface.__init__(self, iface.uri, size)
		self.iface = iface
		self.in_cache = []

	def append_to(self, model, iter):
		iter2 = model.append(iter,
				  [self.uri, self.size, None, summary(self.iface), self])
		for cached_impl in self.in_cache:
			cached_impl.append_to(model, iter2)
	
	def get_may_delete(self):
		for c in self.in_cache:
			if not isinstance(c, LocalImplementation):
				return False	# Still some impls cached
		return True

	may_delete = property(get_may_delete)
	
class InvalidInterface(CachedInterface):
	may_delete = True

	def __init__(self, uri, ex, size):
		CachedInterface.__init__(self, uri, size)
		self.ex = ex

	def append_to(self, model, iter):
		model.append(iter, [self.uri, self.size, None, self.ex, self])
	
class LocalImplementation:
	may_delete = False

	def __init__(self, impl):
		self.impl = impl

	def append_to(self, model, iter):
		model.append(iter, [self.impl.id, 0, None, _('This is a local version, not held in the cache.'), self])

class CachedImplementation:
	may_delete = True

	def __init__(self, cache_dir, name):
		self.impl_path = os.path.join(cache_dir, name)
		self.size = get_size(self.impl_path)
		self.name = name

	def delete(self):
		#print "Delete", self.impl_path
		support.ro_rmtree(self.impl_path)
	
	def open_rox(self):
		os.spawnlp(os.P_WAIT, '0launch', '0launch', ROX_IFACE, '-d', self.impl_path)
	
	def verify(self):
		try:
			manifest.verify(self.impl_path)
		except BadDigest, ex:
			box = gtk.MessageDialog(None, 0,
						gtk.MESSAGE_WARNING, gtk.BUTTONS_OK, str(ex))
			if ex.detail:
				swin = gtk.ScrolledWindow()
				buffer = gtk.TextBuffer()
				mono = buffer.create_tag('mono', family = 'Monospace')
				buffer.insert_with_tags(buffer.get_start_iter(), ex.detail, mono)
				text = gtk.TextView(buffer)
				text.set_editable(False)
				text.set_cursor_visible(False)
				swin.add(text)
				swin.set_shadow_type(gtk.SHADOW_IN)
				swin.set_border_width(4)
				box.vbox.pack_start(swin)
				swin.show_all()
				box.set_resizable(True)
		else:
			box = gtk.MessageDialog(None, 0,
						gtk.MESSAGE_INFO, gtk.BUTTONS_OK,
						_('Contents match digest; nothing has been changed.'))
		box.run()
		box.destroy()

	menu_items = [(_('Open in ROX-Filer'), open_rox),
		      (_('Verify integrity'), verify)]

class UnusedImplementation(CachedImplementation):
	def append_to(self, model, iter):
		model.append(iter, [self.name, self.size, None, self.impl_path, self])

class KnownImplementation(CachedImplementation):
	def __init__(self, cached_iface, cache_dir, impl, impl_size):
		CachedImplementation.__init__(self, cache_dir, impl.id)
		self.cached_iface = cached_iface
		self.impl = impl
		self.size = impl_size
	
	def delete(self):
		CachedImplementation.delete(self)
		self.cached_iface.in_cache.remove(self)

	def append_to(self, model, iter):
		model.append(iter,
			[_('Version %(implementation_version)s : %(implementation_id)s') % {'implementation_version': self.impl.get_version(), 'implementation_id': self.impl.id},
			 self.size, None,
			 None,
			 self])
	
	def __cmp__(self, other):
		if hasattr(other, 'impl'):
			return self.impl.__cmp__(other.impl)
		return -1

class CacheExplorer:
	"""A graphical interface for viewing the cache and deleting old items."""
	def __init__(self, iface_cache):
		widgets = gtkutils.Template(os.path.join(os.path.dirname(__file__), 'cache.ui'), 'cache')
		self.window = window = widgets.get_widget('cache')
		window.set_default_size(gtk.gdk.screen_width() / 2, gtk.gdk.screen_height() / 2)
		self.iface_cache = iface_cache

		# Model
		self.model = gtk.TreeStore(str, int, str, str, object)
		self.tree_view = widgets.get_widget('treeview')
		self.tree_view.set_model(self.model)

		column = gtk.TreeViewColumn(_('Item'), gtk.CellRendererText(), text = ITEM)
		column.set_resizable(True)
		self.tree_view.append_column(column)

		cell = gtk.CellRendererText()
		cell.set_property('xalign', 1.0)
		column = gtk.TreeViewColumn(_('Size'), cell, text = PRETTY_SIZE)
		self.tree_view.append_column(column)

		def button_press(tree_view, bev):
			if bev.button != 3:
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			obj = self.model[path][ITEM_OBJECT]
			if obj and hasattr(obj, 'menu_items'):
				popup_menu(bev, obj)
		self.tree_view.connect('button-press-event', button_press)

		# Tree tooltips
		def motion(tree_view, ev):
			if ev.window is not tree_view.get_bin_window():
				return False
			pos = tree_view.get_path_at_pos(int(ev.x), int(ev.y))
			if pos:
				path = pos[0]
				row = self.model[path]
				tip = row[TOOLTIP]
				if tip:
					if tip != tips.item:
						tips.prime(tree_view, tip)
				else:
					tips.hide()
			else:
				tips.hide()

		self.tree_view.connect('motion-notify-event', motion)
		self.tree_view.connect('leave-notify-event', lambda tv, ev: tips.hide())

		# Responses
		window.set_default_response(gtk.RESPONSE_CLOSE)

		selection = self.tree_view.get_selection()
		def selection_changed(selection):
			any_selected = False
			for x in get_selected_paths(self.tree_view):
				obj = self.model[x][ITEM_OBJECT]
				if obj is None or not obj.may_delete:
					window.set_response_sensitive(DELETE, False)
					return
				any_selected = True
			window.set_response_sensitive(DELETE, any_selected)
		selection.set_mode(gtk.SELECTION_MULTIPLE)
		selection.connect('changed', selection_changed)
		selection_changed(selection)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CLOSE:
				window.destroy()
			elif resp == gtk.RESPONSE_HELP:
				cache_help.display()
			elif resp == DELETE:
				self._delete()
		window.connect('response', response)
	
	def _delete(self):
		errors = []

		model = self.model
		paths = get_selected_paths(self.tree_view)
		paths.reverse()
		for path in paths:
			item = model[path][ITEM_OBJECT]
			assert item.delete
			try:
				item.delete()
			except OSError, ex:
				errors.append(str(ex))
			else:
				model.remove(model.get_iter(path))
		self._update_sizes()

		if errors:
			gtkutils.show_message_box(self, _("Failed to delete:\n%s") % '\n'.join(errors))

	def show(self):
		"""Display the window and scan the caches to populate it."""
		self.window.show()
		self.window.window.set_cursor(gtkutils.get_busy_pointer())
		gtk.gdk.flush()
		try:
			self._populate_model()
			i = self.model.get_iter_root()
			while i:
				self.tree_view.expand_row(self.model.get_path(i), False)
				i = self.model.iter_next(i)
		finally:
			self.window.window.set_cursor(None)

	def _populate_model(self):
		# Find cached implementations

		unowned = {}	# Impl ID -> Store
		duplicates = [] # TODO

		for s in self.iface_cache.stores.stores:
			if os.path.isdir(s.dir):
				for id in os.listdir(s.dir):
					if id in unowned:
						duplicates.append(id)
					unowned[id] = s

		ok_interfaces = []
		error_interfaces = []

		# Look through cached interfaces for implementation owners
		all = self.iface_cache.list_all_interfaces()
		all.sort()
		for uri in all:
			iface_size = 0
			try:
				if uri.startswith('/'):
					cached_iface = uri
				else:
					cached_iface = basedir.load_first_cache(namespaces.config_site,
							'interfaces', model.escape(uri))
				user_overrides = basedir.load_first_config(namespaces.config_site,
							namespaces.config_prog,
							'user_overrides', model.escape(uri))

				iface_size = size_if_exists(cached_iface) + size_if_exists(user_overrides)
				iface = self.iface_cache.get_interface(uri)
			except Exception, ex:
				error_interfaces.append((uri, str(ex), iface_size))
			else:
				cached_iface = ValidInterface(iface, iface_size)
				for impl in iface.implementations.values():
					if impl.id.startswith('/') or impl.id.startswith('.'):
						cached_iface.in_cache.append(LocalImplementation(impl))
					if impl.id in unowned:
						cached_dir = unowned[impl.id].dir
						impl_path = os.path.join(cached_dir, impl.id)
						impl_size = get_size(impl_path)
						cached_iface.in_cache.append(KnownImplementation(cached_iface, cached_dir, impl, impl_size))
						del unowned[impl.id]
				cached_iface.in_cache.sort()
				ok_interfaces.append(cached_iface)

		if error_interfaces:
			iter = self.model.append(None, [_("Invalid interfaces (unreadable)"),
						 0, None,
						 _("These interfaces exist in the cache but cannot be "
						   "read. You should probably delete them."),
						   None])
			for uri, ex, size in error_interfaces:
				item = InvalidInterface(uri, ex, size)
				item.append_to(self.model, iter)

		unowned_sizes = []
		local_dir = os.path.join(basedir.xdg_cache_home, '0install.net', 'implementations')
		for id in unowned:
			if unowned[id].dir == local_dir:
				impl = UnusedImplementation(local_dir, id)
				unowned_sizes.append((impl.size, impl))
		if unowned_sizes:
			iter = self.model.append(None, [_("Unowned implementations and temporary files"),
						0, None,
						_("These probably aren't needed any longer. You can "
						  "delete them."), None])
			unowned_sizes.sort()
			unowned_sizes.reverse()
			for size, item in unowned_sizes:
				item.append_to(self.model, iter)

		if ok_interfaces:
			iter = self.model.append(None,
				[_("Interfaces"),
				 0, None,
				 _("Interfaces in the cache"),
				   None])
			for item in ok_interfaces:
				item.append_to(self.model, iter)
		self._update_sizes()
	
	def _update_sizes(self):
		"""Set PRETTY_SIZE to the total size, including all children."""
		m = self.model
		def update(itr):
			total = m[itr][SELF_SIZE]
			child = m.iter_children(itr)
			while child:
				total += update(child)
				child = m.iter_next(child)
			m[itr][PRETTY_SIZE] = support.pretty_size(total)
			return total
		itr = m.get_iter_root()
		while itr:
			update(itr)
			itr = m.iter_next(itr)

cache_help = help_box.HelpBox(_("Cache Explorer Help"),
(_('Overview'), '\n' +
_("""When you run a program using Zero Install, it downloads the program's 'interface' file, \
which gives information about which versions of the program are available. This interface \
file is stored in the cache to save downloading it next time you run the program.

When you have chosen which version (implementation) of the program you want to \
run, Zero Install downloads that version and stores it in the cache too. Zero Install lets \
you have many different versions of each program on your computer at once. This is useful, \
since it lets you use an old version if needed, and different programs may need to use \
different versions of libraries in some cases.

The cache viewer shows you all the interfaces and implementations in your cache. \
This is useful to find versions you don't need anymore, so that you can delete them and \
free up some disk space.""")),

(_('Invalid interfaces'), '\n' +
_("""The cache viewer gets a list of all interfaces in your cache. However, some may not \
be valid; they are shown in the 'Invalid interfaces' section. It should be fine to \
delete these. An invalid interface may be caused by a local interface that no longer \
exists, by a failed attempt to download an interface (the name ends in '.new'), or \
by the interface file format changing since the interface was downloaded.""")),

(_('Unowned implementations and temporary files'), '\n' +
_("""The cache viewer searches through all the interfaces to find out which implementations \
they use. If no interface uses an implementation, it is shown in the 'Unowned implementations' \
section.

Unowned implementations can result from old versions of a program no longer being listed \
in the interface file. Temporary files are created when unpacking an implementation after \
downloading it. If the archive is corrupted, the unpacked files may be left there. Unless \
you are currently unpacking new programs, it should be fine to delete everything in this \
section.""")),

(_('Interfaces'), '\n' +
_("""All remaining interfaces are listed in this section. You may wish to delete old versions of \
certain programs. Deleting a program which you may later want to run will require it to be downloaded \
again. Deleting a version of a program which is currently running may cause it to crash, so be careful!
""")))
