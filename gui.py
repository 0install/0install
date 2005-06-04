import gtk, os, gobject, sys

from zeroinstall.injector.policy import Policy
from zeroinstall.injector import download
from zeroinstall.injector.model import SafeException
from zeroinstall.injector.reader import InvalidInterface
import dialog

# Singleton Policy
policy = None

class GUIPolicy(Policy):
	window = None
	n_downloads = 0
	pulse = None

	def __init__(self, interface, prog_args, download_only):
		Policy.__init__(self, interface)
		global policy
		assert policy is None
		policy = self

		try:
			self.ready
		except:
			self.ready = True
			print >>sys.stderr, "Your version of the injector is very old. " \
				"Try upgrading (http://0install.net/injector)"

		import mainwindow
		self.window = mainwindow.MainWindow(prog_args, download_only)
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
					gobject.source_remove(self.pulse)
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
			
		gobject.io_add_watch(error_stream,
				     gobject.IO_IN | gobject.IO_HUP,
				     error_ready)

		self.n_downloads += 1
		if self.pulse is None:
			progress = self.window.progress
			self.pulse = gobject.timeout_add(50, lambda: progress.pulse() or True)
			progress.show()
	
	def recalculate(self):
		Policy.recalculate(self)
		self.window.set_response_sensitive(gtk.RESPONSE_OK, self.ready)
	
	def confirm_trust_keys(self, interface, sigs, iface_xml):
		import trust_box
		trust_box.confirm_trust(interface, sigs, iface_xml)

	def main(self):
		self.window.show()
		gtk.main()
	
	def get_best_source(self, impl):
		"""Return the best download source for this implementation."""
		return impl.download_sources[0]

	# XXX: Remove this. Moved to Policy.
	def refresh_all(self, force = True):
		for x in self.walk_interfaces():
			self.begin_iface_download(x, force)

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

