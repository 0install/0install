import gtk

n_windows = 0

last_error = None

class Dialog(gtk.Dialog):
	__shown = False

	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)

		def destroyed(widget):
			if self.__shown:
				_one_less_window()
		self.connect('destroy', destroyed)

	def show(self):
		global n_windows
		n_windows += 1
		self.__shown = True
		gtk.Dialog.show(self)
	
	def add_mixed_button(self, message, stock, response):
		button = MixedButton(message, stock)
		button.set_flags(gtk.CAN_DEFAULT)

		self.add_action_widget(button, response)
		button.show_all()
		return button

def alert(parent, message, type = gtk.MESSAGE_ERROR):
	global n_windows

	if type == gtk.MESSAGE_ERROR:
		global last_error
		last_error = message

	box = gtk.MessageDialog(parent, gtk.DIALOG_DESTROY_WITH_PARENT,
				type, gtk.BUTTONS_OK,
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

def MixedButton(message, stock, x_align = 0.5):
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
	frame.add(content)
	if hasattr(content, 'set_padding'):
		content.set_padding(8, 4)
	else:
		content.set_border_width(8)
	page.pack_start(frame, expand, True, 0)
