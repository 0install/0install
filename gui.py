from policy import Policy
import download
import gtk, os

# Singleton Policy
policy = None

class GUIPolicy(Policy):
	window = None
	n_downloads = 0

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

		self.n_downloads += 1
		if self.n_downloads == 1:
			progress = self.window.progress
			gtk.timeout_add(50, lambda: progress.pulse() or True)
			progress.show()
		#self.window.label.set_text('Fetching ' + dl.url)

		child = os.fork()
		if child == 0:
			try:
				self.child_do_download(dl)
			finally:
				os._exit(1)
		pid, status = os.waitpid(child, 0)
		assert pid == child

		dl.status = download.download_failed

	def main(self):
		self.window.show()
		gtk.main()
	
	def child_do_download(self, dl):
		print "Downloading", dl
