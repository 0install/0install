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

		cell_icon = gtk.CellRendererPixbuf()
		cell_icon.set_property('xpad', 4)
		cell_icon.set_property('ypad', 4)
		column = gtk.TreeViewColumn('Icon', cell_icon, pixbuf = AppListBox.ICON)
		tv.append_column(column)

		cell_text = gtk.CellRendererText()
		column = gtk.TreeViewColumn('Name', cell_text, markup = AppListBox.MARKUP)
		tv.append_column(column)

		model.set_sort_column_id(AppListBox.NAME, gtk.SORT_ASCENDING)

		def response(box, resp):
			box.destroy()
		self.window.connect('response', response)
