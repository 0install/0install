import gtk

gtk.rc_parse_string('style "scrolled" { '
		    'GtkScrolledWindow::scrollbar-spacing = 0}\n'
		    'class "GtkScrolledWindow" style : gtk "scrolled"\n')

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
