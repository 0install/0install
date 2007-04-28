import gtk
import os, sys
import sets	# Note: for Python 2.3; frozenset is only in Python 2.4

from zeroinstall.injector.model import SafeException
from zeroinstall.injector import download, writer
from zeroinstall import support
from gui import policy
from dialog import Dialog

import warnings
warnings.filterwarnings('ignore', category = DeprecationWarning, module='download_box')

def download_with_gui(mainwindow):
	"""If all downloads are ready, prints the selected versions and exits. Otherwise,
	hides mainwindow, shows the download progress box and then prints them.
	On error, mainwindow is re-shown and returns False. Before starting,
	any current downloads (interfaces) are aborted.
	On success, calls sys.exit(0)."""
	try:
		policy.abort_all_downloads()

		# Existing downloads don't disappear until the kill signal takes
		# effect. Rather than waiting, just filter them out later.
		existing_downloads = sets.ImmutableSet(policy.handler.monitored_downloads)

		for iface, impl in policy.get_uncached_implementations():
			if not impl.download_sources:
				raise SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!)")
			source = policy.get_best_source(impl)
			policy.begin_impl_download(impl, source, force = True)
		def run_it():
			policy.abort_all_downloads()

			from zeroinstall.injector import selections
			sels = selections.Selections(policy)
			doc = sels.toDOM()
			reply = doc.toxml('utf-8')
			sys.stdout.write(('Length:%8x\n' % len(reply)) + reply)
			mainwindow.destroy()
			sys.exit(0)			# Success
		if sets.ImmutableSet(policy.handler.monitored_downloads) - existing_downloads:
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

		downloads = [(x, x.expected_size) for x in policy.handler.monitored_downloads
				if hasattr(x, 'expected_size')]

		table = gtk.Table(len(downloads) + 1, 3)
		self.vbox.pack_start(table, False, False, 0)
		table.set_row_spacings(4)
		table.set_col_spacings(10)
		table.set_border_width(10)

		bars = []

		row = 0
		for dl, size in downloads:
			bar = gtk.ProgressBar()
			bars.append((dl, bar))
			table.attach(gtk.Label(os.path.basename(dl.url)),
				0, 1, row, row + 1)
			table.attach(gtk.Label(support.pretty_size(size)),
					1, 2, row, row + 1)
			table.attach(bar, 2, 3, row, row + 1)
			row += 1

		mainwindow.hide()
		self.vbox.show_all()

		def resp(box, resp):
			for dl, size in downloads:
				dl.abort()
			gtk.timeout_remove(self.idle_timeout)
			self.idle_timeout = None
			self.destroy()
			mainwindow.download_box = None
			mainwindow.show()
			policy.recalculate()
		self.connect('response', resp)

		def update_bars():
			if not policy.handler.monitored_downloads:
				if policy.get_uncached_implementations():
					return False
				self.destroy()
				self.run_it()
			for dl, bar in bars:
				perc = dl.get_current_fraction()
				if perc >= 0:
					bar.set_fraction(perc)
			return True

		self.idle_timeout = gtk.timeout_add(250, update_bars)
