from policy import Policy
import download
import gtk

# Singleton Policy
policy = None

class GUIPolicy(Policy):
	window = None

	def __init__(self, interface, prog, prog_args):
		Policy.__init__(self, interface)
		global policy
		assert policy is None
		policy = self

		import mainwindow
		self.window = mainwindow.MainWindow(prog, prog_args)
		self.window.browser.set_root(policy.get_interface(policy.root))

	def start_download(self, dl):
		assert dl.status is download.download_starting
		print "Start"
		self.window.label.set_text('Fetching ' + dl.url)
		dl.status = download.download_failed

	def main(self):
		self.window.show()
		gtk.main()
