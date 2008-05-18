# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
import gtk.glade
import os
from zeroinstall.support import tasks

n_windows = 0

last_error = None

gladefile = os.path.join(os.path.dirname(__file__), 'zero-install.glade')

# Wrapped for glade widget tree that throws a sensible exception if the widget isn't found
class Template:
	def __init__(self, root):
		self.widgets = gtk.glade.XML(gladefile, root)
		self.root = root
	
	def get_widget(self, name = None):
		if not name:
			name = self.root
		widget = self.widgets.get_widget(name)
		assert widget, "Widget '%s' not found in glade file '%s'" % (name, gladefile)
		return widget

class Dialog(gtk.Dialog):
	__shown = False

	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)
	
	def add_mixed_button(self, message, stock, response):
		button = MixedButton(message, stock)
		button.set_flags(gtk.CAN_DEFAULT)

		self.add_action_widget(button, response)
		button.show_all()
		return button

class DialogResponse(tasks.Blocker):
	response = None
	def __init__(self, dialog):
		tasks.Blocker.__init__(self, dialog.get_title())
		a = None
		def response(d, resp):
			self.response = resp
			d.disconnect(a)
			self.trigger()
		a = dialog.connect('response', response)

class ButtonClickedBlocker(tasks.Blocker):
	def __init__(self, button):
		tasks.Blocker.__init__(self, "Button click")
		a = None
		def clicked(b):
			b.disconnect(a)
			self.trigger()
		a = button.connect('clicked', lambda b: self.trigger())

def alert(parent, message, type = gtk.MESSAGE_ERROR):
	if type == gtk.MESSAGE_ERROR:
		global last_error
		last_error = message

	box = gtk.MessageDialog(parent, gtk.DIALOG_DESTROY_WITH_PARENT,
				type, gtk.BUTTONS_OK,
				str(message))
	box.set_position(gtk.WIN_POS_CENTER)
	def resp(b, r):
		b.destroy()
	box.connect('response', resp)
	box.show()

def MixedButton(message, stock, x_align = 0.5, button = None):
	if button is None:
		button = gtk.Button()

	label = gtk.Label('')
	label.set_text_with_mnemonic(message)
	label.set_mnemonic_widget(button)

	image = gtk.image_new_from_stock(stock, gtk.ICON_SIZE_BUTTON)
	box = gtk.HBox(False, 2)
	align = gtk.Alignment(x_align, 0.5, 0.0, 0.0)

	box.pack_start(image, False, False, 0)
	box.pack_end(label, False, False, 0)

	button.add(align)
	align.add(box)
	return button

def frame(page, title, content, expand = False):
	frame = gtk.Frame()
	label = gtk.Label()
	label.set_markup('<b>%s</b>' % title)
	frame.set_label_widget(label)
	frame.set_shadow_type(gtk.SHADOW_NONE)
	if type(content) in (str, unicode):
		content = gtk.Label(content)
		content.set_alignment(0, 0.5)
		content.set_selectable(True)
	frame.add(content)
	if hasattr(content, 'set_padding'):
		content.set_padding(8, 4)
	else:
		content.set_border_width(8)
	page.pack_start(frame, expand, True, 0)

def get_busy_pointer(gdk_window):
	# This is crazy. We build a cursor that looks like the old
	# Netscape busy-with-a-pointer cursor and set that, then the
	# X server replaces it with a decent-looking one!!
	# See http://mail.gnome.org/archives/gtk-list/2007-May/msg00100.html

	bit_data = "\
\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\
\x0c\x00\x00\x00\x1c\x00\x00\x00\x3c\x00\x00\x00\
\x7c\x00\x00\x00\xfc\x00\x00\x00\xfc\x01\x00\x00\
\xfc\x3b\x00\x00\x7c\x38\x00\x00\x6c\x54\x00\x00\
\xc4\xdc\x00\x00\xc0\x44\x00\x00\x80\x39\x00\x00\
\x80\x39\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00"

	try:
		pix = gtk.gdk.bitmap_create_from_data(None, bit_data, 32, 32)
		color = gtk.gdk.Color()
		return gtk.gdk.Cursor(pix, pix, color, color, 2, 2)
	except:
		#old bug http://bugzilla.gnome.org/show_bug.cgi?id=103616
		return gtk.gdk.Cursor(gtk.gdk.WATCH)
