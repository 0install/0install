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

class ImplBox(gtk.HBox):
	def __init__(self, selection):
		gtk.HBox.__init__(self, False, 0)
		self.set_border_width(4)

		impl_model = gtk.ListStore(str, str, bool)

		swin = gtk.ScrolledWindow()
		self.pack_start(swin, True, True, 0)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		impl = gtk.TreeView(impl_model)
		swin.add(impl)

		text = gtk.CellRendererText()
		column = gtk.TreeViewColumn(_('Version'), text, text = 0)
		impl.append_column(column)

		toggle = gtk.CellRendererToggle()
		column = gtk.TreeViewColumn(_('Disable'), toggle, active = 2)
		impl.append_column(column)

		column = gtk.TreeViewColumn(_('Implementation'), text, text = 1)
		impl.append_column(column)

		def update_interface(selection):
			store, itr = selection.get_selected()
			impl_model.clear()
			if not itr:
				return
			iface = store[itr][DepBrowser.INTERFACE]
			selected_version = store[itr][DepBrowser.VERSION]
			for impl in iface.implementations:
				itr = impl_model.append()
				impl_model[itr][0] = impl.get_version()
				impl_model[itr][1] = impl.path

		selection.connect('changed', update_interface)

class DepBrowser(gtk.Dialog):
	# Columns in model
	INTERFACE = 0
	INTERFACE_NAME = 1
	VERSION = 2
	IMPLEMENTATION = 3

	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_title(_('Injector dependancy browser'))
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

		if w.run() == gtk.RESPONSE_OK:
			return selection
		sys.exit(0)
