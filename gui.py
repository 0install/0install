import sys
import pygtk; pygtk.require('2.0')
import gtk

from policy import Policy
import interface

def _(x): return x

gtk.rc_parse_string('style "scrolled" { GtkScrolledWindow::scrollbar-spacing = 0}\n'
		      'class "GtkScrolledWindow" style : gtk "scrolled"\n')

class Field(gtk.Label):
	def __init__(self, name, value):
		gtk.Label.__init__(self, name + ': ' + value)
		self._name = name
		self.set_padding(4, 4)
		self.set_alignment(0, 0.5)
	
	def set_text(self, value):
		gtk.Label.set_text(self, self._name + ': ' + value)

class IFaceBox(gtk.VBox):
	def __init__(self, selection):
		gtk.VBox.__init__(self, False, 0)
		self.set_border_width(4)

		iface_name = Field('Interface', '(none selected)')

		self.pack_start(iface_name, False, True, 0)

		frame = gtk.Frame()
		iface_desc = gtk.Label('')
		frame.add(iface_desc)
		self.pack_start(frame, False, True, 0)

		self.show_all()

		def update_interface(selection):
			store, itr = selection.get_selected()
			if itr:
				iface = store[itr][DepBrowser.INTERFACE]
				iface_name.set_text("'%s' (%s)" %
						(iface.name, iface.path))
				iface_desc.set_text(iface.description)
			else:
				iface_name.set_text('(none selected)')
				iface_desc.set_text('')
		selection.connect('changed', update_interface)

def get_menu_choice(bev, choices, callback):
	menu = gtk.Menu()
	for i in choices:
		item = gtk.MenuItem(i)
		item.connect('activate', lambda item, i = i: callback(i))
		item.show()
		menu.append(item)
	menu.popup(None, None, None, bev.button, bev.time)


class ImplBox(gtk.HBox):
	def __init__(self, selection):
		gtk.HBox.__init__(self, False, 0)
		self.set_border_width(4)

		version_model = gtk.ListStore(str, str)

		swin = gtk.ScrolledWindow()
		self.pack_start(swin, False, True, 0)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_policy(gtk.POLICY_NEVER, gtk.POLICY_ALWAYS)
		version_tree = gtk.TreeView(version_model)
		swin.add(version_tree)

		text = gtk.CellRendererText()

		use_column = gtk.TreeViewColumn(_('Use'), text, text = 0)
		version_tree.append_column(use_column)

		column = gtk.TreeViewColumn(_('Version'), text, text = 1)
		version_tree.append_column(column)

		def version_button(tree, bev):
			if bev.button != 1:
				return False
			pos = tree.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			if col is not use_column:
				return False
			version = version_model[path][1]
			def set_version_use(use):
				print version, use
			get_menu_choice(bev, ['Preferred', 'Normal', 'Disabled'],
					set_version_use)
		version_tree.connect('button-press-event', version_button)


		impl_model = gtk.ListStore(str, str)

		swin = gtk.ScrolledWindow()
		self.pack_start(swin, True, True, 0)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		impl = gtk.TreeView(impl_model)
		swin.add(impl)

		column = gtk.TreeViewColumn(_('Use'), text, text = 0)
		impl.append_column(column)
		column = gtk.TreeViewColumn(_('Implementation'), text, text = 1)
		impl.append_column(column)

		def update_interface(selection):
			store, itr = selection.get_selected()
			impl_model.clear()
			version_model.clear()
			if not itr:
				return
			iface = store[itr][DepBrowser.INTERFACE]
			selected_version = store[itr][DepBrowser.VERSION]
			versions = {}
			for impl in iface.implementations:
				versions[tuple(impl.version)] = True
			versions = versions.keys()
			versions.sort()
			for v in versions:
				itr = version_model.append()
				version_str = '.'.join(map(str, v))
				version_model[itr][1] = version_str
				if version_str == selected_version:
					version_tree.get_selection().select_iter(itr)
					version_tree.scroll_to_cell(version_model.get_path(itr))

		selection.connect('changed', update_interface)

		def update_version(ver_selection):
			ver_store, ver_itr = ver_selection.get_selected()
			impl_model.clear()
			if not ver_itr:
				return
			iface_store, iface_itr = selection.get_selected()

			iface = iface_store[iface_itr][DepBrowser.INTERFACE]
			selected_version = ver_store[ver_itr][1]
			for impl in iface.implementations:
				if impl.get_version() == selected_version:
					itr = impl_model.append()
					impl_model[itr][1] = impl.path
		version_tree.get_selection().connect('changed', update_version)

class DepBrowser(gtk.Dialog):
	# Columns in model
	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	IMPLEMENTATION = 3

	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_title(_('Injector dependancy browser'))
		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_OK, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)
		self.set_has_separator(False)

		self.model = gtk.TreeStore(object, str, str, str)
	
		swin = gtk.ScrolledWindow()
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		swin.set_border_width(4)
		swin.set_shadow_type(gtk.SHADOW_IN)
		self.vbox.pack_start(swin, True, True, 0)
		
		tv = gtk.TreeView(self.model)
		swin.add(tv)

		text = gtk.CellRendererText()

		column = gtk.TreeViewColumn(_('Interface'), text,
					  text = DepBrowser.INTERFACE_NAME)
		tv.append_column(column)

		column = gtk.TreeViewColumn(_('Version'), text,
					  text = DepBrowser.VERSION)
		tv.append_column(column)

		column = gtk.TreeViewColumn(_('Version location'), text,
					  text = DepBrowser.IMPLEMENTATION)
		tv.append_column(column)
		self.tv = tv

		iface_box = IFaceBox(tv.get_selection())
		self.vbox.pack_start(iface_box, False, True, 0)

		imp_box = ImplBox(tv.get_selection())
		self.vbox.pack_start(imp_box, True, True, 0)

		self.vbox.show_all()

		self.set_default_size(gtk.gdk.screen_width() / 2,
				      gtk.gdk.screen_height() / 3)
	
	def set_selection(self, root, selection):
		done = {}
		def add(iface, parent):
			if iface in done:
				return
			done[iface] = True

			imp = selection[iface]

			itr = self.model.append(parent)
			self.model[itr][DepBrowser.INTERFACE] = iface
			self.model[itr][DepBrowser.INTERFACE_NAME] = iface.name
			self.model[itr][DepBrowser.VERSION] = imp.get_version()
			self.model[itr][DepBrowser.IMPLEMENTATION] = imp.path

			for x in imp.dependancies:
				add(x.get_interface(),  itr)
		add(root, None)
		self.tv.expand_all()

class InteractivePolicy(Policy):
	def choose_best(self, iface):
		w = DepBrowser()
		w.show()
		gtk.gdk.flush()

		selection = Policy.choose_best(self, iface)

		w.set_selection(iface, selection)

		w.zero_done = False

		def response(box, resp):
			if resp == gtk.RESPONSE_HELP:
				import help
				help.show_help()
			elif resp == gtk.RESPONSE_OK:
				w.destroy()
				w.zero_done = True
				gtk.main_quit()
			else:
				sys.exit(0)
		w.connect('response', response)

		w.show()

		while True:
			gtk.main()
			if w.zero_done:
				return selection
