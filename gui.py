from policy import Policy
import download
import gtk, os
import dialog
from reader import InvalidInterface
from model import SafeException

# Singleton Policy
policy = None

class GUIPolicy(Policy):
	window = None
	n_downloads = 0
	pulse = None

	def __init__(self, interface, prog_args):
		Policy.__init__(self, interface)
		global policy
		assert policy is None
		policy = self

		import mainwindow
		self.window = mainwindow.MainWindow(prog_args)
		self.window.browser.set_root(policy.get_interface(policy.root))

	def monitor_download(self, dl):
		error_stream = dl.start()
		def error_ready(src, cond):
			got = os.read(src.fileno(), 100)
			if not got:
				error_stream.close()
				self.n_downloads -= 1
				if self.n_downloads == 0:
					self.window.progress.hide()
					gtk.timeout_remove(self.pulse)
					self.pulse = None
				try:
					data = dl.error_stream_closed()
					self.check_signed_data(dl, data)
				except download.DownloadError, ex:
					dialog.alert(self.window,
						"Error downloading interface '%s':\n\n%s" %
						(dl.interface.uri, ex))
				except InvalidInterface, ex:
					dialog.alert(self.window,
						"Syntax error in downloaded interface '%s':\n\n%s" %
						(dl.interface.uri, ex))
				except SafeException, ex:
					dialog.alert(self.window,
						"Error updating interface '%s':\n\n%s" %
						(dl.interface.uri, ex))
				return False
			dl.error_stream_data(got)
			return True
			
		gtk.input_add(error_stream, gtk.gdk.INPUT_READ, error_ready)

		self.n_downloads += 1
		if self.pulse is None:
			progress = self.window.progress
			self.pulse = gtk.timeout_add(50, lambda: progress.pulse() or True)
			progress.show()
	
	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		trust_box.trust_box.confirm_trust(interface, sigs, iface_xml)

	def main(self):
		self.window.show()
		gtk.main()

def pretty_size(size):
	if size is None:
		return '?'
	if size < 2048:
		return '%d bytes' % size
	size = float(size)
	for unit in ('Kb', 'Mb', 'Gb', 'Tb'):
		size /= 1024
		if size < 2048:
			break
	return '%.1f %s' % (size, unit)

