# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, gobject, pango

from zeroinstall.support import tasks, pretty_size
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector import model
import properties
from zeroinstall.gtkui.treetips import TreeTips
from zeroinstall import support
from logging import warn
import utils

def _stability(impl):
	assert impl
	if impl.user_stability is None:
		return impl.upstream_stability
	return _("%(implementation_user_stability)s (was %(implementation_upstream_stability)s)") \
		% {'implementation_user_stability': impl.user_stability, 'implementation_upstream_stability': impl.upstream_stability}

ICON_SIZE = 20.0
CELL_TEXT_INDENT = int(ICON_SIZE) + 4

class InterfaceTips(TreeTips):
	mainwindow = None

	def __init__(self, mainwindow):
		self.mainwindow = mainwindow

	def get_tooltip_text(self):
		interface, model_column = self.item
		assert interface
		if model_column == InterfaceBrowser.INTERFACE_NAME:
			return _("Full name: %s") % interface.uri
		elif model_column == InterfaceBrowser.SUMMARY:
			if not interface.description:
				return None
			first_para = interface.description.split('\n\n', 1)[0]
			return first_para.replace('\n', ' ')
		elif model_column is None:
			return _("Click here for more options...")

		impl = self.mainwindow.policy.implementation.get(interface, None)
		if not impl:
			return _("No suitable implementation was found. Check the "
				 "interface properties to find out why.")

		if model_column == InterfaceBrowser.VERSION:
			text = _("Currently preferred version: %(version)s (%(stability)s)") % \
					{'version': impl.get_version(), 'stability': _stability(impl)}
			old_impl = self.mainwindow.original_implementation.get(interface, None)
			if old_impl is not None and old_impl is not impl:
				text += '\n' + _('Previously preferred version: %(version)s (%(stability)s)') % \
					{'version': old_impl.get_version(), 'stability': _stability(old_impl)}
			return text

		assert model_column == InterfaceBrowser.DOWNLOAD_SIZE

		if self.mainwindow.policy.get_cached(impl):
			return _("This version is already stored on your computer.")
		else:
			src = self.mainwindow.policy.fetcher.get_best_source(impl)
			if not src:
				return _("No downloads available!")
			return _("Need to download %(pretty_size)s (%(size)s bytes)") % \
					{'pretty_size': support.pretty_size(src.size), 'size': src.size}

class MenuIconRenderer(gtk.GenericCellRenderer):
	def __init__(self):
		gtk.GenericCellRenderer.__init__(self)
		self.set_property('mode', gtk.CELL_RENDERER_MODE_ACTIVATABLE)

	def do_set_property(self, prop, value):
		setattr(self, prop.name, value)

	def on_get_size(self, widget, cell_area, layout = None):
		return (0, 0, 20, 20)

	def on_render(self, window, widget, background_area, cell_area, expose_area, flags):
		if flags & gtk.CELL_RENDERER_PRELIT:
			state = gtk.STATE_PRELIGHT
		else:
			state = gtk.STATE_NORMAL

		widget.style.paint_box(window, state, gtk.SHADOW_OUT, expose_area, widget, None,
					cell_area.x, cell_area.y, cell_area.width, cell_area.height)
		widget.style.paint_arrow(window, state, gtk.SHADOW_NONE, expose_area, widget, None,
					gtk.ARROW_RIGHT, True,
					cell_area.x + 5, cell_area.y + 5, cell_area.width - 10, cell_area.height - 10)

class IconAndTextRenderer(gtk.GenericCellRenderer):
	__gproperties__ = {
		"image": (gobject.TYPE_OBJECT, "Image", "Image", gobject.PARAM_READWRITE),
		"text": (gobject.TYPE_STRING, "Text", "Text", "-", gobject.PARAM_READWRITE),
	}

	def do_set_property(self, prop, value):
		setattr(self, prop.name, value)

	def on_get_size(self, widget, cell_area, layout = None):
		if not layout:
			layout = widget.create_pango_layout(self.text)
		a, rect = layout.get_pixel_extents()

		pixmap_height = self.image.get_height()

		both_height = max(rect[1] + rect[3], pixmap_height)

		return (0, 0,
			rect[0] + rect[2] + CELL_TEXT_INDENT,
			both_height)

	def on_render(self, window, widget, background_area, cell_area, expose_area, flags):
		layout = widget.create_pango_layout(self.text)
		a, rect = layout.get_pixel_extents()

		if flags & gtk.CELL_RENDERER_SELECTED:
			state = gtk.STATE_SELECTED
		elif flags & gtk.CELL_RENDERER_PRELIT:
			state = gtk.STATE_PRELIGHT
		else:
			state = gtk.STATE_NORMAL

		image_y = int(0.5 * (cell_area.height - self.image.get_height()))
		window.draw_pixbuf(widget.style.white_gc, self.image, 0, 0,
				cell_area.x,
				cell_area.y + image_y)

		text_y = int(0.5 * (cell_area.height - (rect[1] + rect[3])))

		widget.style.paint_layout(window, state, True,
			expose_area, widget, "cellrenderertext",
			cell_area.x + CELL_TEXT_INDENT,
			cell_area.y + text_y,
			layout)

if gtk.pygtk_version < (2, 8, 0):
	# Note sure exactly which versions need this.
	# 2.8.0 gives a warning if you include it, though.
	gobject.type_register(IconAndTextRenderer)
	gobject.type_register(MenuIconRenderer)

class InterfaceBrowser:
	model = None
	root = None
	cached_icon = None
	policy = None
	original_implementation = None
	update_icons = False

	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	SUMMARY = 3
	DOWNLOAD_SIZE = 4
	ICON = 5

	columns = [(_('Component'), INTERFACE_NAME),
		   (_('Version'), VERSION),
		   (_('Fetch'), DOWNLOAD_SIZE),
		   (_('Description'), SUMMARY),
		   ('', None)]

	def __init__(self, policy, widgets):
		tips = InterfaceTips(self)

		tree_view = widgets.get_widget('components')

		self.policy = policy
		self.cached_icon = {}	# URI -> GdkPixbuf
		self.default_icon = tree_view.style.lookup_icon_set(gtk.STOCK_EXECUTE).render_icon(tree_view.style,
			gtk.TEXT_DIR_NONE, gtk.STATE_NORMAL, gtk.ICON_SIZE_SMALL_TOOLBAR, tree_view, None)

		self.model = gtk.TreeStore(object, str, str, str, str, gtk.gdk.Pixbuf)
		self.tree_view = tree_view
		tree_view.set_model(self.model)

		column_objects = []

		text = gtk.CellRendererText()

		for name, model_column in self.columns:
			if model_column == InterfaceBrowser.INTERFACE_NAME:
				column = gtk.TreeViewColumn(name, IconAndTextRenderer(),
						text = model_column,
						image = InterfaceBrowser.ICON)
			elif model_column == None:
				menu_column = column = gtk.TreeViewColumn('', MenuIconRenderer())
			else:
				if model_column == InterfaceBrowser.SUMMARY:
					text_ellip = gtk.CellRendererText()
					try:
						text_ellip.set_property('ellipsize', pango.ELLIPSIZE_END)
					except:
						pass
					column = gtk.TreeViewColumn(name, text_ellip, text = model_column)
					column.set_expand(True)
				else:
					column = gtk.TreeViewColumn(name, text, text = model_column)
			tree_view.append_column(column)
			column_objects.append(column)

		tree_view.set_enable_search(True)

		selection = tree_view.get_selection()

		def motion(tree_view, ev):
			if ev.window is not tree_view.get_bin_window():
				return False
			pos = tree_view.get_path_at_pos(int(ev.x), int(ev.y))
			if pos:
				path = pos[0]
				try:
					col_index = column_objects.index(pos[1])
				except ValueError:
					tips.hide()
				else:
					col = self.columns[col_index][1]
					row = self.model[path]
					item = (row[InterfaceBrowser.INTERFACE], col)
					if item != tips.item:
						tips.prime(tree_view, item)
			else:
				tips.hide()

		tree_view.connect('motion-notify-event', motion)
		tree_view.connect('leave-notify-event', lambda tv, ev: tips.hide())

		def button_press(tree_view, bev):
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos

			if (bev.button == 3 or (bev.button < 4 and col is menu_column)) \
			   and bev.type == gtk.gdk.BUTTON_PRESS:
				selection.select_path(path)
				iface = self.model[path][InterfaceBrowser.INTERFACE]
				self.show_popup_menu(iface, bev)
				return True
			if bev.button != 1 or bev.type != gtk.gdk._2BUTTON_PRESS:
				return False
			properties.edit(policy, self.model[path][InterfaceBrowser.INTERFACE])
		tree_view.connect('button-press-event', button_press)

		tree_view.connect('destroy', lambda s: policy.watchers.remove(self.build_tree))
		policy.watchers.append(self.build_tree)

	def set_root(self, root):
		assert isinstance(root, model.Interface)
		self.root = root

	def set_update_icons(self, update_icons):
		if update_icons:
			# Clear icons cache to make sure they're really updated
			self.cached_icon = {}
		self.update_icons = update_icons
	
	def _load_icon(self, path):
		assert path
		try:
			loader = gtk.gdk.PixbufLoader('png')
			try:
				loader.write(file(path).read())
			finally:
				loader.close()
			icon = loader.get_pixbuf()
			assert icon, "Failed to load cached PNG icon data"
		except Exception, ex:
			warn(_("Failed to load cached PNG icon: %s"), ex)
			return None
		w = icon.get_width()
		h = icon.get_height()
		scale = max(w, h, 1) / ICON_SIZE
		icon = icon.scale_simple(int(w / scale),
					 int(h / scale),
					 gtk.gdk.INTERP_BILINEAR)
		return icon

	def get_icon(self, iface):
		"""Get an icon for this interface. If the icon is in the cache, use that.
		If not, start a download. If we already started a download (successful or
		not) do nothing. Returns None if no icon is currently available."""
		try:
			# Try the in-memory cache
			return self.cached_icon[iface.uri]
		except KeyError:
			# Try the on-disk cache
			iconpath = iface_cache.get_icon_path(iface)

			if iconpath:
				icon = self._load_icon(iconpath)
				# (if icon is None, cache the fact that we can't load it)
				self.cached_icon[iface.uri] = icon
			else:
				icon = None

			# Download a new icon if we don't have one, or if the
			# user did a 'Refresh'
			if iconpath is None or self.update_icons:
				fetcher = self.policy.download_icon(iface)
				if fetcher:
					if iface.uri not in self.cached_icon:
						self.cached_icon[iface.uri] = None	# Only try once

					@tasks.async
					def update_display():
						yield fetcher
						try:
							tasks.check(fetcher)
							# Try to insert new icon into the cache
							# If it fails, we'll be left with None in the cached_icon so
							# we don't try again.
							iconpath = iface_cache.get_icon_path(iface)
							if iconpath:
								self.cached_icon[iface.uri] = self._load_icon(iconpath)
								self.build_tree()
							else:
								warn("Failed to download icon for '%s'", iface)
						except Exception, ex:
							import traceback
							traceback.print_exc()
							self.policy.handler.report_error(ex)
					update_display()
				# elif fetcher is None: don't store anything in cached_icon

			# Note: if no icon is available for downloading,
			# more attempts are made later.
			# It can happen that no icon is yet available because
			# the interface was not downloaded yet, in which case
			# it's desireable to try again once the interface is available
			return icon

		return None

	def build_tree(self):
		if self.original_implementation is None:
			self.set_original_implementations()

		done = {}	# Detect cycles

		self.model.clear()
		parent = None
		def add_node(parent, iface):
			if iface in done:
				return
			done[iface] = True

			iter = self.model.append(parent)
			self.model[iter][InterfaceBrowser.INTERFACE] = iface
			self.model[iter][InterfaceBrowser.INTERFACE_NAME] = iface.get_name()
			self.model[iter][InterfaceBrowser.SUMMARY] = iface.summary
			self.model[iter][InterfaceBrowser.ICON] = self.get_icon(iface) or self.default_icon

			impl = self.policy.implementation.get(iface, None)
			if impl:
				old_impl = self.original_implementation.get(iface, None)
				version_str = impl.get_version()
				if old_impl is not None and old_impl.id != impl.id:
					version_str += _(' (was %s)') % old_impl.get_version()
				self.model[iter][InterfaceBrowser.VERSION] = version_str

				self.model[iter][InterfaceBrowser.DOWNLOAD_SIZE] = utils.get_fetch_info(self.policy, impl)
				children = self.policy.solver.requires[iface]

				for child in children:
					if isinstance(child, model.InterfaceDependency):
						add_node(iter, iface_cache.get_interface(child.interface))
					else:
						child_iter = self.model.append(parent)
						self.model[child_iter][InterfaceBrowser.INTERFACE_NAME] = '?'
						self.model[child_iter][InterfaceBrowser.SUMMARY] = \
							_('Unknown dependency type : %s') % child
						self.model[child_iter][InterfaceBrowser.ICON] = self.default_icon
			else:
				self.model[iter][InterfaceBrowser.VERSION] = _('(choose)')
		add_node(None, self.root)
		self.tree_view.expand_all()
	
	def show_popup_menu(self, iface, bev):
		import bugs
		import compile

		have_source =  properties.have_source_for(self.policy, iface)

		menu = gtk.Menu()
		for label, cb in [(_('Show Feeds'), lambda: properties.edit(self.policy, iface)),
				  (_('Show Versions'), lambda: properties.edit(self.policy, iface, show_versions = True)),
				  (_('Report a Bug...'), lambda: bugs.report_bug(self.policy, iface))]:
			item = gtk.MenuItem(label)
			if cb:
				item.connect('activate', lambda item, cb=cb: cb())
			else:
				item.set_sensitive(False)
			item.show()
			menu.append(item)

		item = gtk.MenuItem(_('Compile'))
		item.show()
		menu.append(item)
		if have_source:
			compile_menu = gtk.Menu()
			item.set_submenu(compile_menu)

			item = gtk.MenuItem(_('Automatic'))
			item.connect('activate', lambda item: compile.compile(self.policy, iface, autocompile = True))
			item.show()
			compile_menu.append(item)

			item = gtk.MenuItem(_('Manual...'))
			item.connect('activate', lambda item: compile.compile(self.policy, iface, autocompile = False))
			item.show()
			compile_menu.append(item)
		else:
			item.set_sensitive(False)

		menu.popup(None, None, None, bev.button, bev.time)
	
	def set_original_implementations(self):
		assert self.original_implementation is None
		self.original_implementation = self.policy.implementation.copy()

	def update_download_status(self):
		"""Called at regular intervals while there are downloads in progress,
		and once at the end. Also called when things are added to the store.
		Update the TreeView with the interfaces."""
		hints = {}
		for dl in self.policy.handler.monitored_downloads.values():
			if dl.hint:
				if dl.hint not in hints:
					hints[dl.hint] = []
				hints[dl.hint].append(dl)
			
		selections = self.policy.solver.selections

		def walk(it):
			while it:
				yield self.model[it]
				for x in walk(self.model.iter_children(it)): yield x
				it = self.model.iter_next(it)

		for row in walk(self.model.get_iter_root()):
			iface = row[InterfaceBrowser.INTERFACE]
			
			# Is this interface the download's hint?
			downloads = hints.get(iface, [])	# The interface itself	
		     	downloads += hints.get(iface.uri, [])	# The main feed
			for feed in iface.feeds:
				downloads += hints.get(feed.uri, []) # Other feeds
			impl = selections.get(iface, None)
			if impl:
				downloads += hints.get(impl, []) # The chosen implementation

			if downloads:
				so_far = 0
				expected = None
				for dl in downloads:
					if dl.expected_size:
						expected = (expected or 0) + dl.expected_size
					so_far += dl.get_bytes_downloaded_so_far()
				if expected:
					summary = ngettext("(downloading %(downloaded)s/%(expected)s [%(percentage).2f%%])",
							   "(downloading %(downloaded)s/%(expected)s [%(percentage).2f%%] in %(number)d downloads)",
							   downloads)
					values_dict = {'downloaded': pretty_size(so_far), 'expected': pretty_size(expected), 'percentage': 100 * so_far / float(expected), 'number': len(downloads)}
				else:
					summary = ngettext("(downloading %(downloaded)s/unknown)",
							   "(downloading %(downloaded)s/unknown in %(number)d downloads)",
							   downloads)
					values_dict = {'downloaded': pretty_size(so_far), 'number': len(downloads)}
				row[InterfaceBrowser.SUMMARY] = summary % values_dict
			else:
				row[InterfaceBrowser.DOWNLOAD_SIZE] = utils.get_fetch_info(self.policy, impl)
				row[InterfaceBrowser.SUMMARY] = iface.summary
