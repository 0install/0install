# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, gobject, pango

from zeroinstall.support import tasks, pretty_size
from zeroinstall.injector import model, reader
import properties
from zeroinstall.gtkui.icon import load_icon
from zeroinstall import support
from logging import warn, info
import utils

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

	impl = mainwindow.policy.implementation.get(interface, None)
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

	if mainwindow.policy.get_cached(impl):
		return _("This version is already stored on your computer.")
	else:
		src = mainwindow.policy.fetcher.get_best_source(impl)
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
	BACKGROUND = 6

	columns = [(_('Component'), INTERFACE_NAME),
		   (_('Version'), VERSION),
		   (_('Fetch'), DOWNLOAD_SIZE),
		   (_('Description'), SUMMARY),
		   ('', None)]

	def __init__(self, policy, widgets):
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
					main_feed = self.policy.config.iface_cache.get_feed(iface.uri)
					tooltip.set_text(get_tooltip_text(self, iface, main_feed, col))
				return True
			else:
				return False
		tree_view.connect('query-tooltip', callback)

		self.policy = policy
		self.cached_icon = {}	# URI -> GdkPixbuf
		self.default_icon = tree_view.style.lookup_icon_set(gtk.STOCK_EXECUTE).render_icon(tree_view.style,
			gtk.TEXT_DIR_NONE, gtk.STATE_NORMAL, gtk.ICON_SIZE_SMALL_TOOLBAR, tree_view, None)

		self.model = gtk.TreeStore(object, str, str, str, str, gtk.gdk.Pixbuf, str)
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
			properties.edit(policy, self.model[path][InterfaceBrowser.INTERFACE], self.compile, show_versions = True)
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

	def get_icon(self, iface):
		"""Get an icon for this interface. If the icon is in the cache, use that.
		If not, start a download. If we already started a download (successful or
		not) do nothing. Returns None if no icon is currently available."""
		try:
			# Try the in-memory cache
			return self.cached_icon[iface.uri]
		except KeyError:
			# Try the on-disk cache
			iconpath = self.policy.config.iface_cache.get_icon_path(iface)

			if iconpath:
				icon = load_icon(iconpath, ICON_SIZE, ICON_SIZE)
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
							iconpath = self.policy.config.iface_cache.get_icon_path(iface)
							if iconpath:
								self.cached_icon[iface.uri] = load_icon(iconpath, ICON_SIZE, ICON_SIZE)
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
		iface_cache = self.policy.config.iface_cache

		if self.original_implementation is None:
			self.set_original_implementations()

		done = {}	# Detect cycles

		self.model.clear()
		commands = self.policy.solver.selections.commands
		def add_node(parent, iface, command):
			# (command is the index into commands, if any)
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
			self.model[iter][InterfaceBrowser.SUMMARY] = summary
			self.model[iter][InterfaceBrowser.ICON] = self.get_icon(iface) or self.default_icon

			sel = self.policy.solver.selections.selections.get(iface.uri, None)
			if sel:
				impl = sel.impl
				old_impl = self.original_implementation.get(iface, None)
				version_str = impl.get_version()
				if old_impl is not None and old_impl.id != impl.id:
					version_str += _(' (was %s)') % old_impl.get_version()
				self.model[iter][InterfaceBrowser.VERSION] = version_str

				self.model[iter][InterfaceBrowser.DOWNLOAD_SIZE] = utils.get_fetch_info(self.policy, impl)

				deps = sel.dependencies
				if command is not None:
					deps += commands[command].requires
				for child in deps:
					if isinstance(child, model.InterfaceDependency):
						if child.qdom.name == 'runner':
							child_command = command + 1
						else:
							child_command = None
						add_node(iter, iface_cache.get_interface(child.interface), child_command)
					else:
						child_iter = self.model.append(parent)
						self.model[child_iter][InterfaceBrowser.INTERFACE_NAME] = '?'
						self.model[child_iter][InterfaceBrowser.SUMMARY] = \
							_('Unknown dependency type : %s') % child
						self.model[child_iter][InterfaceBrowser.ICON] = self.default_icon
			else:
				self.model[iter][InterfaceBrowser.VERSION] = _('(problem)')
				self.model[iter][InterfaceBrowser.BACKGROUND] = '#f88'
		if commands:
			add_node(None, self.root, 0)
		else:
			# Nothing could be selected, or no command requested
			add_node(None, self.root, None)
		self.tree_view.expand_all()

	def show_popup_menu(self, iface, bev):
		import bugs

		have_source =  properties.have_source_for(self.policy, iface)

		menu = gtk.Menu()
		for label, cb in [(_('Show Feeds'), lambda: properties.edit(self.policy, iface, self.compile)),
				  (_('Show Versions'), lambda: properties.edit(self.policy, iface, self.compile, show_versions = True)),
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
			item.connect('activate', lambda item: self.compile(iface, autocompile = True))
			item.show()
			compile_menu.append(item)

			item = gtk.MenuItem(_('Manual...'))
			item.connect('activate', lambda item: self.compile(iface, autocompile = False))
			item.show()
			compile_menu.append(item)
		else:
			item.set_sensitive(False)

		menu.popup(None, None, None, bev.button, bev.time)

	def compile(self, interface, autocompile = False):
		import compile
		def on_success():
			# A new local feed may have been registered, so reload it from the disk cache
			info(_("0compile command completed successfully. Reloading interface details."))
			reader.update_from_cache(interface)
			for feed in interface.extra_feeds:
				 self.policy.config.iface_cache.get_feed(feed.uri, force = True)
			self.policy.recalculate()
		compile.compile(on_success, interface.uri, autocompile = autocompile)

	def set_original_implementations(self):
		assert self.original_implementation is None
		self.original_implementation = self.policy.implementation.copy()

	def update_download_status(self):
		"""Called at regular intervals while there are downloads in progress,
		and once at the end. Also called when things are added to the store.
		Update the TreeView with the interfaces."""

		# A download may be for a feed, an interface or an implementation.
		# Create the reverse mapping (item -> download)
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
			for feed in self.policy.usable_feeds(iface):
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
