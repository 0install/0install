# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, pango

from zeroinstall import _, translation
from zeroinstall.support import tasks, pretty_size
from zeroinstall.injector import model, reader, download
import properties
from zeroinstall.gtkui.icon import load_icon
from zeroinstall import support
from logging import warn, info
import utils
from gui import gobject

ngettext = translation.ngettext

def _stability(impl):
	assert impl
	if impl.user_stability is None:
		return _(str(impl.upstream_stability))
	return _("%(implementation_user_stability)s (was %(implementation_upstream_stability)s)") \
		% {'implementation_user_stability': _(str(impl.user_stability)),
		   'implementation_upstream_stability': _(str(impl.upstream_stability))}

ICON_SIZE = 20.0
CELL_TEXT_INDENT = int(ICON_SIZE) + 4

def get_tooltip_text(mainwindow, interface, main_feed, model_column):
	assert interface
	if model_column == InterfaceBrowser.INTERFACE_NAME:
		return _("Full name: %s") % interface.uri
	elif model_column == InterfaceBrowser.SUMMARY:
		if main_feed is None or not main_feed.description:
			return _("(no description available)")
		first_para = main_feed.description.split('\n\n', 1)[0]
		return first_para.replace('\n', ' ')
	elif model_column is None:
		return _("Click here for more options...")

	impl = mainwindow.driver.solver.selections.get(interface, None)
	if not impl:
		return _("No suitable version was found. Double-click "
			 "here to find out why.")

	if model_column == InterfaceBrowser.VERSION:
		text = _("Currently preferred version: %(version)s (%(stability)s)") % \
				{'version': impl.get_version(), 'stability': _stability(impl)}
		old_impl = mainwindow.original_implementation.get(interface, None)
		if old_impl is not None and old_impl is not impl:
			text += '\n' + _('Previously preferred version: %(version)s (%(stability)s)') % \
				{'version': old_impl.get_version(), 'stability': _stability(old_impl)}
		return text

	assert model_column == InterfaceBrowser.DOWNLOAD_SIZE

	if impl.is_available(mainwindow.driver.config.stores):
		return _("This version is already stored on your computer.")
	else:
		src = mainwindow.driver.config.fetcher.get_best_source(impl)
		if not src:
			return _("No downloads available!")
		return _("Need to download %(pretty_size)s (%(size)s bytes)") % \
				{'pretty_size': support.pretty_size(src.size), 'size': src.size}

import math
angle_right = math.pi / 2
class MenuIconRenderer(gtk.GenericCellRenderer):
	def __init__(self):
		gtk.GenericCellRenderer.__init__(self)
		self.set_property('mode', gtk.CELL_RENDERER_MODE_ACTIVATABLE)

	def do_set_property(self, prop, value):
		setattr(self, prop.name, value)

	def do_get_size(self, widget, cell_area, layout = None):
		return (0, 0, 20, 20)
	on_get_size = do_get_size		# GTK 2

	if gtk.pygtk_version >= (2, 90):
		# note: if you get "TypeError: Couldn't find conversion for foreign struct 'cairo.Context'", you need "python3-gi-cairo"
		def do_render(self, cr, widget, background_area, cell_area, flags):	# GTK 3
			context = widget.get_style_context()
			gtk.render_arrow(context, cr, angle_right,
						cell_area.x + 5, cell_area.y + 5, max(cell_area.width, cell_area.height) - 10)
	else:
		def on_render(self, window, widget, background_area, cell_area, expose_area, flags):	# GTK 2
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
		"image": (gobject.TYPE_PYOBJECT, "Image", "Image", gobject.PARAM_READWRITE),
		"text": (gobject.TYPE_STRING, "Text", "Text", "-", gobject.PARAM_READWRITE),
	}

	def do_set_property(self, prop, value):
		setattr(self, prop.name, value)

	def do_get_size(self, widget, cell_area, layout = None):
		if not layout:
			layout = widget.create_pango_layout(self.text)
		a, rect = layout.get_pixel_extents()

		if self.image:
			pixmap_height = self.image.get_height()
		else:
			pixmap_height = 32

		if not isinstance(rect, tuple):
			rect = (rect.x, rect.y, rect.width, rect.height)	# GTK 3

		both_height = max(rect[1] + rect[3], pixmap_height)

		return (0, 0,
			rect[0] + rect[2] + CELL_TEXT_INDENT,
			both_height)
	on_get_size = do_get_size 	# GTK 2

	if gtk.pygtk_version >= (2, 90):
		def do_render(self, cr, widget, background_area, cell_area, flags):	# GTK 3
			layout = widget.create_pango_layout(self.text)
			a, rect = layout.get_pixel_extents()
			context = widget.get_style_context()

			image_y = int(0.5 * (cell_area.height - self.image.get_height()))
			gtk.render_icon(context, cr, self.image, cell_area.x, cell_area.y + image_y)

			text_y = int(0.5 * (cell_area.height - (rect.y + rect.height)))

			gtk.render_layout(context, cr,
				cell_area.x + CELL_TEXT_INDENT,
				cell_area.y + text_y,
				layout)
	else:
		def on_render(self, window, widget, background_area, cell_area, expose_area, flags):	# GTK 2
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

def walk(model, it):
	while it:
		yield it
		for x in walk(model, model.iter_children(it)): yield x
		it = model.iter_next(it)

class InterfaceBrowser(object):
	model = None
	root = None
	cached_icon = None
	driver = None
	config = None
	original_implementation = None
	update_icons = False

	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	SUMMARY = 3
	DOWNLOAD_SIZE = 4
	ICON = 5
	BACKGROUND = 6
	PROBLEM = 7

	columns = [(_('Component'), INTERFACE_NAME),
		   (_('Version'), VERSION),
		   (_('Fetch'), DOWNLOAD_SIZE),
		   (_('Description'), SUMMARY),
		   ('', None)]

	def __init__(self, driver, widgets):
		self.driver = driver
		self.config = driver.config

		tree_view = widgets.get_widget('components')
		tree_view.set_property('has-tooltip', True)
		def callback(widget, x, y, keyboard_mode, tooltip):
			x, y = tree_view.convert_widget_to_bin_window_coords(x, y)
			pos = tree_view.get_path_at_pos(x, y)
			if pos:
				tree_view.set_tooltip_cell(tooltip, pos[0], pos[1], None)
				path = pos[0]
				try:
					col_index = column_objects.index(pos[1])
				except ValueError:
					return False
				else:
					col = self.columns[col_index][1]
					row = self.model[path]
					iface = row[InterfaceBrowser.INTERFACE]
					main_feed = self.config.iface_cache.get_feed(iface.uri)
					tooltip.set_text(get_tooltip_text(self, iface, main_feed, col))
				return True
			else:
				return False
		tree_view.connect('query-tooltip', callback)

		self.cached_icon = {}	# URI -> GdkPixbuf
		self.default_icon = tree_view.get_style().lookup_icon_set(gtk.STOCK_EXECUTE).render_icon(tree_view.get_style(),
			gtk.TEXT_DIR_NONE, gtk.STATE_NORMAL, gtk.ICON_SIZE_SMALL_TOOLBAR, tree_view, None)

		self.model = gtk.TreeStore(object, str, str, str, str, gobject.TYPE_PYOBJECT, str, bool)
		self.tree_view = tree_view
		tree_view.set_model(self.model)

		column_objects = []

		text = gtk.CellRendererText()
		coloured_text = gtk.CellRendererText()

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
				elif model_column == InterfaceBrowser.VERSION:
					column = gtk.TreeViewColumn(name, coloured_text, text = model_column,
								    background = InterfaceBrowser.BACKGROUND)
				else:
					column = gtk.TreeViewColumn(name, text, text = model_column)
			tree_view.append_column(column)
			column_objects.append(column)

		tree_view.set_enable_search(True)

		selection = tree_view.get_selection()

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
			properties.edit(driver, self.model[path][InterfaceBrowser.INTERFACE], self.compile, show_versions = True)
		tree_view.connect('button-press-event', button_press)

		tree_view.connect('destroy', lambda s: driver.watchers.remove(self.build_tree))
		driver.watchers.append(self.build_tree)

	def set_root(self, root):
		assert isinstance(root, model.Interface)
		self.root = root

	def set_update_icons(self, update_icons):
		if update_icons:
			# Clear icons cache to make sure they're really updated
			self.cached_icon = {}
		self.update_icons = update_icons

	def get_icon(self, iface):
		"""Get an icon for this interface. If the icon is in the cache, use that.
		If not, start a download. If we already started a download (successful or
		not) do nothing. Returns None if no icon is currently available."""
		try:
			# Try the in-memory cache
			return self.cached_icon[iface.uri]
		except KeyError:
			# Try the on-disk cache
			iconpath = self.config.iface_cache.get_icon_path(iface)

			if iconpath:
				icon = load_icon(iconpath, ICON_SIZE, ICON_SIZE)
				# (if icon is None, cache the fact that we can't load it)
				self.cached_icon[iface.uri] = icon
			else:
				icon = None

			# Download a new icon if we don't have one, or if the
			# user did a 'Refresh'
			if iconpath is None or self.update_icons:
				if self.config.network_use == model.network_offline:
					fetcher = None
				else:
					fetcher = self.config.fetcher.download_icon(iface)
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
							iconpath = self.config.iface_cache.get_icon_path(iface)
							if iconpath:
								self.cached_icon[iface.uri] = load_icon(iconpath, ICON_SIZE, ICON_SIZE)
								self.build_tree()
							else:
								warn("Failed to download icon for '%s'", iface)
						except download.DownloadAborted as ex:
							info("Icon download aborted: %s", ex)
							# Don't report further; the user knows they cancelled
						except download.DownloadError as ex:
							warn("Icon download failed: %s", ex)
							# Not worth showing a dialog box for this
						except Exception as ex:
							import traceback
							traceback.print_exc()
							self.config.handler.report_error(ex)
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
		iface_cache = self.config.iface_cache

		if self.original_implementation is None:
			self.set_original_implementations()

		done = {}	# Detect cycles

		sels = self.driver.solver.selections

		self.model.clear()
		def add_node(parent, iface, commands, essential):
			if iface in done:
				return
			done[iface] = True

			main_feed = iface_cache.get_feed(iface.uri)
			if main_feed:
				name = main_feed.get_name()
				summary = main_feed.summary
			else:
				name = iface.get_name()
				summary = None

			iter = self.model.append(parent)
			self.model[iter][InterfaceBrowser.INTERFACE] = iface
			self.model[iter][InterfaceBrowser.INTERFACE_NAME] = name
			self.model[iter][InterfaceBrowser.SUMMARY] = summary or ''
			self.model[iter][InterfaceBrowser.ICON] = self.get_icon(iface) or self.default_icon
			self.model[iter][InterfaceBrowser.PROBLEM] = False

			sel = sels.selections.get(iface.uri, None)
			if sel:
				impl = sel.impl
				old_impl = self.original_implementation.get(iface, None)
				version_str = impl.get_version()
				if old_impl is not None and old_impl.id != impl.id:
					version_str += _(' (was %s)') % old_impl.get_version()
				self.model[iter][InterfaceBrowser.VERSION] = version_str

				self.model[iter][InterfaceBrowser.DOWNLOAD_SIZE] = utils.get_fetch_info(self.config, impl)

				deps = sel.dependencies
				for c in commands:
					deps += sel.get_command(c).requires
				for child in deps:
					if isinstance(child, model.InterfaceDependency):
						add_node(iter,
							 iface_cache.get_interface(child.interface),
							 child.get_required_commands(),
							 child.importance == model.Dependency.Essential)
					elif not isinstance(child, model.InterfaceRestriction):
						child_iter = self.model.append(parent)
						self.model[child_iter][InterfaceBrowser.INTERFACE_NAME] = '?'
						self.model[child_iter][InterfaceBrowser.SUMMARY] = \
							_('Unknown dependency type : %s') % child
						self.model[child_iter][InterfaceBrowser.ICON] = self.default_icon
			else:
				self.model[iter][InterfaceBrowser.PROBLEM] = essential
				self.model[iter][InterfaceBrowser.VERSION] = _('(problem)') if essential else _('(none)')
		try:
			if sels.command:
				add_node(None, self.root, [sels.command], essential = True)
			else:
				add_node(None, self.root, [], essential = True)
			self.tree_view.expand_all()
		except Exception as ex:
			warn("Failed to build tree: %s", ex, exc_info = ex)
			raise

	def show_popup_menu(self, iface, bev):
		import bugs

		have_source =  properties.have_source_for(self.config, iface)

		global menu		# Fix GC problem in PyGObject
		menu = gtk.Menu()
		for label, cb in [(_('Show Feeds'), lambda: properties.edit(self.driver, iface, self.compile)),
				  (_('Show Versions'), lambda: properties.edit(self.driver, iface, self.compile, show_versions = True)),
				  (_('Report a Bug...'), lambda: bugs.report_bug(self.driver, iface))]:
			item = gtk.MenuItem()
			item.set_label(label)
			if cb:
				item.connect('activate', lambda item, cb=cb: cb())
			else:
				item.set_sensitive(False)
			item.show()
			menu.append(item)

		item = gtk.MenuItem()
		item.set_label(_('Compile'))
		item.show()
		menu.append(item)
		if have_source:
			compile_menu = gtk.Menu()
			item.set_submenu(compile_menu)

			item = gtk.MenuItem()
			item.set_label(_('Automatic'))
			item.connect('activate', lambda item: self.compile(iface, autocompile = True))
			item.show()
			compile_menu.append(item)

			item = gtk.MenuItem()
			item.set_label(_('Manual...'))
			item.connect('activate', lambda item: self.compile(iface, autocompile = False))
			item.show()
			compile_menu.append(item)
		else:
			item.set_sensitive(False)

		if gtk.pygtk_version >= (2, 90):
			menu.popup(None, None, None, None, bev.button, bev.time)
		else:
			menu.popup(None, None, None, bev.button, bev.time)

	def compile(self, interface, autocompile = True):
		import compile
		def on_success():
			# A new local feed may have been registered, so reload it from the disk cache
			info(_("0compile command completed successfully. Reloading interface details."))
			reader.update_from_cache(interface)
			for feed in interface.extra_feeds:
				self.config.iface_cache.get_feed(feed.uri, force = True)
			import main
			main.recalculate()
		compile.compile(on_success, interface.uri, autocompile = autocompile)

	def set_original_implementations(self):
		assert self.original_implementation is None
		self.original_implementation = self.driver.solver.selections.copy()

	def update_download_status(self, only_update_visible = False):
		"""Called at regular intervals while there are downloads in progress,
		and once at the end. Also called when things are added to the store.
		Update the TreeView with the interfaces."""

		# A download may be for a feed, an interface or an implementation.
		# Create the reverse mapping (item -> download)
		hints = {}
		for dl in self.config.handler.monitored_downloads:
			if dl.hint:
				if dl.hint not in hints:
					hints[dl.hint] = []
				hints[dl.hint].append(dl)

		selections = self.driver.solver.selections

		# Only update currently visible rows
		if only_update_visible and self.tree_view.get_visible_range() != None:
			firstVisiblePath, lastVisiblePath = self.tree_view.get_visible_range()
			firstVisibleIter = self.model.get_iter(firstVisiblePath)
		else:
			# (or should we just wait until the TreeView has settled enough to tell
			# us what is visible?)
			firstVisibleIter = self.model.get_iter_root()
			lastVisiblePath = None

		solver = self.driver.solver
		requirements = self.driver.requirements
		iface_cache = self.config.iface_cache

		for it in walk(self.model, firstVisibleIter):
			row = self.model[it]
			iface = row[InterfaceBrowser.INTERFACE]

			# Is this interface the download's hint?
			downloads = hints.get(iface, [])	# The interface itself
			downloads += hints.get(iface.uri, [])	# The main feed

			arch = solver.get_arch_for(requirements, iface)
			for feed in iface_cache.usable_feeds(iface, arch):
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
				feed = iface_cache.get_feed(iface.uri)
				row[InterfaceBrowser.DOWNLOAD_SIZE] = utils.get_fetch_info(self.config, impl)
				row[InterfaceBrowser.SUMMARY] = feed.summary if feed else "-"

			if self.model.get_path(it) == lastVisiblePath:
				break

	def highlight_problems(self):
		"""Called when the solve finishes. Highlight any missing implementations."""
		for it in walk(self.model, self.model.get_iter_root()):
			row = self.model[it]
			iface = row[InterfaceBrowser.INTERFACE]
			sel = self.driver.solver.selections.selections.get(iface.uri, None)

			if sel is None and row[InterfaceBrowser.PROBLEM]:
				row[InterfaceBrowser.BACKGROUND] = '#f88'
