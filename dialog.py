import gtk

n_windows = 0

class Dialog(gtk.Dialog):
	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)

		def destroyed(widget):
			_one_less_window()
		self.connect('destroy', destroyed)

	def show(self):
		global n_windows
		n_windows += 1
		gtk.Dialog.show(self)
	
	def add_mixed_button(self, message, stock, response):
		button = gtk.Button()

		label = gtk.Label('')
		label.set_text_with_mnemonic(message)
		label.set_mnemonic_widget(button)

		image = gtk.image_new_from_stock(stock, gtk.ICON_SIZE_BUTTON)
		box = gtk.HBox(False, 2)
		align = gtk.Alignment(0.5, 0.5, 0.0, 0.0)

		box.pack_start(image, False, False, 0)
		box.pack_end(label, False, False, 0)

		button.add(align)
		align.add(box)
		button.set_flags(gtk.CAN_DEFAULT)

		self.add_action_widget(button, response)
		button.show_all()

def alert(parent, message):
	global n_windows
	box = gtk.MessageDialog(parent, gtk.DIALOG_DESTROY_WITH_PARENT,
				gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
				str(message))
	box.set_position(gtk.WIN_POS_CENTER)
	def resp(b, r):
		box.destroy()
		_one_less_window()
	box.connect('response', resp)
	box.show()
	n_windows += 1

def _one_less_window():
	global n_windows
	n_windows -= 1
	if n_windows == 0:
		gtk.main_quit()

def wait_for_no_windows():
	while n_windows > 0:
		gtk.main()
