import gtk

n_windows = 0

class Dialog(gtk.Dialog):
	def __init__(self):
		global n_windows
		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)

		def destroyed(widget):
			global n_windows
			n_windows -= 1
			if n_windows == 0:
				gtk.main_quit()
		self.connect('destroy', destroyed)

		n_windows += 1

def alert(parent, message):
	box = gtk.MessageDialog(parent, gtk.DIALOG_DESTROY_WITH_PARENT,
				gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
				message)
	box.set_position(gtk.WIN_POS_CENTER)
	box.connect('response', lambda b, r: box.destroy())
	box.show()
