"""A dialog box for displaying help text."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import gtk

class HelpBox:
	"""A dialog for showing longish help texts.
	The GTK widget is not created until L{display} is called.
	"""
	box = None
	title = None
	sections = None

	def __init__(self, title, *sections):
		"""Constructor.
		@param title: window title
		@param sections: the content, as a list of (section_title, section_body) pairs
		@type sections: [(str, str)]"""
		self.title = title
		self.sections = sections
	
	def display(self):
		"""Display this help text. If it is already displayed, close the old window first."""
		if self.box:
			self.box.destroy()
			assert not self.box

		self.box = box = gtk.Dialog()
		self.box.set_has_separator(False)
		self.box.set_position(gtk.WIN_POS_CENTER)
		box.set_title(self.title)
		box.set_has_separator(False)

		swin = gtk.ScrolledWindow(None, None)
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_border_width(2)
		box.vbox.pack_start(swin, True, True)

		text = gtk.TextView()
		text.set_left_margin(4)
		text.set_right_margin(4)
		text.set_wrap_mode(gtk.WRAP_WORD)
		text.set_editable(False)
		text.set_cursor_visible(False)
		model = text.get_buffer()
		titer = model.get_start_iter()
		heading_style = model.create_tag(underline = True, scale = 1.2)

		first = True
		for title, body in self.sections:
			if first:
				first = False
			else:
				model.insert(titer, '\n\n')
			model.insert_with_tags(titer, title, heading_style)
			model.insert(titer, '\n' + body.strip())
		swin.add(text)

		swin.show_all()

		box.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CANCEL)
		box.connect('response', lambda box, resp: box.destroy())

		box.set_default_response(gtk.RESPONSE_CANCEL)

		def destroyed(box):
			self.box = None
		box.connect('destroy', destroyed)

		box.set_position(gtk.WIN_POS_CENTER)
		box.set_default_size(gtk.gdk.screen_width() / 4,
				      gtk.gdk.screen_height() / 3)
		box.show()
