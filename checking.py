import gtk, gobject

from dialog import Dialog

class CheckingBox(Dialog):
	def __init__(self, root):
		Dialog.__init__(self)
		self.set_title("Checking for updates")
		label = gtk.Label("Checking for updates to '%s'..." % root.get_name())
		label.set_padding(10, 10)
		self.vbox.pack_start(label, True, True, 0)
		self.vbox.show_all()

		self.progress = gtk.ProgressBar()
		self.vbox.pack_start(self.progress, False, True, 0)
		self.progress.show()

		self.add_mixed_button('Details...', gtk.STOCK_ZOOM_IN, gtk.RESPONSE_OK)
		self.connect('response', lambda w, r: self.destroy())
	
	def updates_done(self):
		"""Close the dialog after a short delay"""
		self.set_response_sensitive(gtk.RESPONSE_OK, False)
		gobject.timeout_add(500, self.destroy)
