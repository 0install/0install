# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
import os
from zeroinstall.support import tasks
from zeroinstall.gtkui import gtkutils

n_windows = 0

last_error = None

builderfile = os.path.join(os.path.dirname(__file__), 'zero-install.ui')

class Template(gtkutils.Template):
	def __init__(self, root):
		gtkutils.Template.__init__(self, builderfile, root)

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

	gtkutils.show_message_box(parent, message, type)

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
