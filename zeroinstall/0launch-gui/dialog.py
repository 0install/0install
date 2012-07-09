# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from zeroinstall.gtkui import gtkutils, gtk

last_error = None

builderfile = os.path.join(os.path.dirname(__file__), 'zero-install.ui')

class Template(gtkutils.Template):
	def __init__(self, root):
		gtkutils.Template.__init__(self, builderfile, root)

class Dialog(gtk.Dialog):
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

def alert(parent, message, type = gtk.MESSAGE_ERROR):
	if type == gtk.MESSAGE_ERROR:
		global last_error
		last_error = message

	gtkutils.show_message_box(parent, message, type)

DialogResponse = gtkutils.DialogResponse
ButtonClickedBlocker = gtkutils.ButtonClickedBlocker
MixedButton = gtkutils.MixedButton
