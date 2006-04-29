import gtk
import os, sys

from zeroinstall.injector.model import SafeException
from zeroinstall.injector import download, run
from gui import policy, pretty_size
from dialog import Dialog

import warnings
warnings.filterwarnings('ignore', category = DeprecationWarning, module='download_box')

def download_with_gui(mainwindow, prog_args, run_afterwards, main = None):
	"""If all downloads are ready, runs the program. Otherwise,
	hides mainwindow, shows the download progress box and then runs
	it. On error, mainwindow is re-shown and returns False.
	On success, doesn't return (calls exec, or sys.exit(0) if nothing to exec)."""
	try:
		for iface, impl in policy.get_uncached_implementations():
			if not impl.download_sources:
				raise SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!)")
			source = policy.get_best_source(impl)
			if hasattr(policy, 'begin_impl_download'):
				policy.begin_impl_download(impl, source, force = True)
			else:
				dl = download.begin_impl_download(source, force = True)
				policy.monitor_download(dl)
		def run_it():
			policy.abort_all_downloads()
			if not run_afterwards:
				mainwindow.destroy()
				sys.exit(0)			# Success
			if main is None:
				run.execute(policy, prog_args)	# Don't break older versions
			else:
				run.execute(policy, prog_args, main = main)
			# Not reached, unless this is a dry run
			mainwindow.destroy()
			sys.exit(0)			# Success
		if policy.monitored_downloads:
			DownloadProgessBox(run_it, mainwindow).show()
		else:
			run_it()
	except SafeException, ex:
		box = gtk.MessageDialog(None, gtk.DIALOG_MODAL,
				gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
				str(ex))
		box.run()
		box.destroy()
		mainwindow.show()

class DownloadProgessBox(Dialog):
	mainwindow = None
	run_it = None
	idle_timeout = None
	errors = False

	def __init__(self, run_it, mainwindow):
		Dialog.__init__(self)
		self.set_title('Downloading, please wait...')
		self.mainwindow = mainwindow
		assert self.mainwindow.download_box is None
		self.mainwindow.download_box = self
		self.run_it = run_it

		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)

		downloads = [x for x in policy.monitored_downloads
				if isinstance(x, download.ImplementationDownload)]

		table = gtk.Table(len(downloads) + 1, 3)
		self.vbox.pack_start(table, False, False, 0)
		table.set_row_spacings(4)
		table.set_col_spacings(10)
		table.set_border_width(10)

		bars = []

		row = 0
		for dl in downloads:
			bar = gtk.ProgressBar()
			bars.append((dl, bar))
			table.attach(gtk.Label(os.path.basename(dl.url)),
				0, 1, row, row + 1)
			table.attach(gtk.Label(pretty_size(dl.source.size)),
					1, 2, row, row + 1)
			table.attach(bar, 2, 3, row, row + 1)
			row += 1

		mainwindow.hide()
		self.vbox.show_all()

		def resp(box, resp):
			for dl in downloads:
				dl.abort()
			gtk.timeout_remove(self.idle_timeout)
			self.idle_timeout = None
			self.destroy()
			mainwindow.download_box = None
			mainwindow.show()
			policy.recalculate()
		self.connect('response', resp)

		def update_bars():
			if not policy.monitored_downloads:
				if policy.get_uncached_implementations():
					return False
				self.destroy()
				self.run_it()
			for dl, bar in bars:
				perc = dl.get_current_fraction()
				bar.set_fraction(perc)
			return True

		self.idle_timeout = gtk.timeout_add(250, update_bars)
