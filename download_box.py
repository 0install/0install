import gtk
import os

from model import SafeException
from gui import policy, pretty_size
from dialog import Dialog
import download
import dialog

def download_and_run(mainwindow, prog_args):
	"""If all downloads are ready, runs the program. Otherwise,
	hides mainwindow, shows the download progress box and then runs
	it. On error, mainwindow is re-shown."""
	downloads = []
	for iface, impl in policy.get_uncached_implementations():
		if not impl.download_sources:
			raise SafeException("Implementation " + impl + " of "
				"interface " + iface + " cannot be "
				"downloaded (no download locations given in "
				"interface!")
		dl = download.begin_impl_download(impl.download_sources[0],
						force = True)
		downloads.append((iface, dl))
	def run_it():
		import run
		try:
			run.execute(policy, prog_args)
			mainwindow.destroy()
		except SafeException, ex:
			box = gtk.MessageDialog(None, gtk.DIALOG_MODAL,
					gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
					str(ex))
			box.run()
			box.destroy()
			mainwindow.show()
	if downloads:
		DownloadProgessBox(run_it, downloads, mainwindow).show()
	else:
		run_it()

class DownloadProgessBox(Dialog):
	mainwindow = None
	run_it = None
	n_downloads = None
	idle_timeout = None

	def __init__(self, run_it, downloads, mainwindow):
		Dialog.__init__(self)
		self.set_title('Downloading, please wait...')
		self.mainwindow = mainwindow
		self.run_it = run_it
		self.n_downloads = 0

		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)

		table = gtk.Table(len(downloads) + 1, 3)
		self.vbox.pack_start(table, False, False, 0)
		table.set_row_spacings(4)
		table.set_col_spacings(10)
		table.set_border_width(10)

		bars = []

		row = 0
		for iface, dl in downloads:
			bar = gtk.ProgressBar()
			bars.append((dl, bar))
			table.attach(gtk.Label(iface.get_name()),
				0, 1, row, row + 1)
			table.attach(gtk.Label(pretty_size(dl.source.size)),
					1, 2, row, row + 1)
			table.attach(bar, 2, 3, row, row + 1)
			row += 1
			self.start_download(dl)

		mainwindow.hide()
		self.vbox.show_all()

		def resp(box, resp):
			for iface, dl in downloads:
				dl.abort()
			gtk.timeout_remove(self.idle_timeout)
			self.idle_timeout = None
			self.destroy()
			mainwindow.show()
		self.connect('response', resp)

		def update_bars():
			if self.n_downloads == 0:
				self.destroy()
				self.run_it()
				return False
			for dl, bar in bars:
				perc = dl.get_current_fraction()
				bar.set_fraction(perc)
			return True

		self.idle_timeout = gtk.timeout_add(250, update_bars)
	
	def start_download(self, dl):
		error_stream = dl.start()
		def error_ready(src, cond):
			got = os.read(src.fileno(), 100)
			if not got:
				error_stream.close()
				self.n_downloads -= 1
				try:
					data = dl.error_stream_closed()
				except download.DownloadError, ex:
					dialog.alert(self,
						"Error downloading '%s':\n\n%s" %
						(dl.url, ex))
				try:
					policy.add_to_cache(dl.source, data)
				except SafeException, ex:
					dialog.alert(self,
						"Error unpacking '%s':\n\n%s" %
						(dl.url, ex))
				return False
			dl.error_stream_data(got)
			return True
			
		self.n_downloads += 1
		gtk.input_add(error_stream, gtk.gdk.INPUT_READ, error_ready)
