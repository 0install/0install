"""A GTK dialog which displays a list of Zero Install applications in the menu."""
# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
import gtk
import gtk.glade

from zeroinstall.gtkui import icon, xdgutils

class AppListBox:
	"""A dialog box which lists applications already added to the menus."""
	ICON, URI, NAME, MARKUP = range(4)

	def __init__(self, iface_cache):
		gladefile = os.path.join(os.path.dirname(__file__), 'desktop.glade')

		widgets = gtk.glade.XML(gladefile, 'applist')
		self.window = widgets.get_widget('applist')
		tv = widgets.get_widget('treeview')

		model = gtk.ListStore(gtk.gdk.Pixbuf, str, str, str)
		apps = xdgutils.discover_existing_apps()

		for uri in apps:
			itr = model.append()
			model[itr][AppListBox.URI] = uri

			iface = iface_cache.get_interface(uri)
			name = iface.get_name()
			summary = iface.summary or 'No information available'
			summary = summary[:1].capitalize() + summary[1:]

			model[itr][AppListBox.NAME] = name
			pixbuf = icon.load_icon(iface_cache.get_icon_path(iface))
			if pixbuf:
				model[itr][AppListBox.ICON] = pixbuf

			model[itr][AppListBox.MARKUP] = '<b>%s</b>\n<i>%s</i>' % (name.replace('<', '&lt;'), summary.replace('<', '&lt;'))

		tv.set_model(model)
		tv.get_selection().set_mode(gtk.SELECTION_NONE)

		cell_icon = gtk.CellRendererPixbuf()
		cell_icon.set_property('xpad', 4)
		cell_icon.set_property('ypad', 4)
		column = gtk.TreeViewColumn('Icon', cell_icon, pixbuf = AppListBox.ICON)
		tv.append_column(column)

		cell_text = gtk.CellRendererText()
		column = gtk.TreeViewColumn('Name', cell_text, markup = AppListBox.MARKUP)
		tv.append_column(column)

		cell_actions = ActionsRenderer(tv)
		column = gtk.TreeViewColumn('Actions', cell_actions)
		tv.append_column(column)

		model.set_sort_column_id(AppListBox.NAME, gtk.SORT_ASCENDING)

		def response(box, resp):
			box.destroy()
		self.window.connect('response', response)

class ActionsRenderer(gtk.GenericCellRenderer):
	def __init__(self, widget):
		"@param widget: widget used for style information"
		gtk.GenericCellRenderer.__init__(self)
		self.set_property('mode', gtk.CELL_RENDERER_MODE_ACTIVATABLE)
		self.padding = 4

		self.size = 10
		def stock_lookup(name):
			pixbuf = widget.render_icon(name, gtk.ICON_SIZE_BUTTON)
			self.size = max(self.size, pixbuf.get_width(), pixbuf.get_height())
			return pixbuf

		if hasattr(gtk, 'STOCK_MEDIA_PLAY'):
			self.run = stock_lookup(gtk.STOCK_MEDIA_PLAY)
		else:
			self.run = stock_lookup(gtk.STOCK_YES)
		self.help = stock_lookup(gtk.STOCK_HELP)
		self.properties = stock_lookup(gtk.STOCK_PROPERTIES)
		self.remove = stock_lookup(gtk.STOCK_DELETE)

	def do_set_property(self, prop, value):
		setattr(self, prop.name, value)

	def on_get_size(self, widget, cell_area, layout = None):
		total_size = self.size * 2 + self.padding * 4
		return (0, 0, total_size, total_size)

	def on_render(self, window, widget, background_area, cell_area, expose_area, flags):
		s = self.size

		cx = cell_area.x + self.padding
		cy = cell_area.y + (cell_area.height / 2) - s - self.padding

		ss = s + self.padding * 2

		for (x, y), icon in [((0, 0), self.run),
			     ((ss, 0), self.help),
			     ((0, ss), self.properties),
			     ((ss, ss), self.remove)]:
			if flags & gtk.CELL_RENDERER_PRELIT:
				widget.style.paint_box(window, gtk.STATE_NORMAL, gtk.SHADOW_OUT,
						expose_area, widget, None,
						cx + x, cy + y, s, s)

			window.draw_pixbuf(widget.style.white_gc, icon,
						0, 0,		# Source x,y
						cx + x, cy + y)

if gtk.pygtk_version < (2, 8, 0):
	# Note sure exactly which versions need this.
	# 2.8.0 gives a warning if you include it, though.
	gobject.type_register(ActionsRenderer)
