# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import sys
import logging
import warnings
import locale

from zeroinstall import localedir

if localedir:
	# Tell GTK where to find the translations, if they're not in
	# the default system location.
	if hasattr(locale, 'bindtextdomain'):
		locale.bindtextdomain('zero-install', localedir)

from optparse import OptionParser

from zeroinstall import _, SafeException
from zeroinstall.injector.config import load_config
from zeroinstall.support import tasks

_recalculate = tasks.Blocker('recalculate')

def recalculate():
	"""Ask the mainloop to recalculate. If we're already recalculating, wait for that to finish
	and then do it again."""
	global _recalculate
	_recalculate.trigger()
	_recalculate = tasks.Blocker('recalculate')

def check_gui():
	"""Returns True if the GUI works, or returns an exception if not."""
	if sys.version_info[0] < 3:
		try:
			import pygtk; pygtk.require('2.0')
		except ImportError as ex:
			logging.info("No GUI available", exc_info = ex)
			return ex

	try:
		if sys.version_info[0] > 2:
			from zeroinstall.gtkui import pygtkcompat
			pygtkcompat.enable()
			pygtkcompat.enable_gtk(version = '3.0')
		import gtk
	except (ImportError, ValueError, RuntimeError) as ex:
		logging.info("No GUI available", exc_info = ex)
		return ex

	if gtk.gdk.get_display() is None:
		return SafeException("Failed to connect to display.")

	return True

_gui_available = None
def gui_is_available(force_gui):
	"""True if we have a usable GUI. False to fallback on console mode.
	If force_gui is True, raise an exception if the GUI is missing."""
	global _gui_available
	if _gui_available is None:
		with warnings.catch_warnings():
			if not force_gui:
				warnings.filterwarnings("ignore")
			_gui_available = check_gui()

	if _gui_available is True:
		return True
	if force_gui:
		raise _gui_available
	return False

class OCamlDriver:
	def __init__(self, config):
		self.config = config
		self.watchers = []

	def set_selections(self, ready, tree, sels):
		self.ready = ready
		self.tree = tree
		self.sels = sels

		for w in self.watchers: w()

def open_gui(args):
	parser = OptionParser(usage=_("usage: %prog [options] interface"))
	parser.add_option("", "--before", help=_("choose a version before this"), metavar='VERSION')
	parser.add_option("", "--cpu", help=_("target CPU type"), metavar='CPU')
	parser.add_option("", "--command", help=_("command to select"), metavar='COMMAND')
	parser.add_option("-d", "--download-only", help=_("fetch but don't run"), action='store_true')
	parser.add_option("-g", "--force-gui", help=_("display an error if there's no GUI"), action='store_true')
	parser.add_option("", "--message", help=_("message to display when interacting with user"))
	parser.add_option("", "--not-before", help=_("minimum version to choose"), metavar='VERSION')
	parser.add_option("", "--os", help=_("target operation system type"), metavar='OS')
	parser.add_option("-r", "--refresh", help=_("check for updates of all interfaces"), action='store_true')
	parser.add_option("", "--select-only", help=_("only download the feeds"), action='store_true')
	parser.add_option("-s", "--source", help=_("select source code"), action='store_true')
	parser.add_option("", "--systray", help=_("download in the background"), action='store_true')
	parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
	parser.add_option("-V", "--version", help=_("display version information"), action='store_true')
	parser.add_option("", "--version-for", help=_("set version constraints for a specific interface"),
			nargs=2, metavar='URI RANGE', action='append')
	parser.add_option("", "--with-store", help=_("add an implementation cache"), action='append', metavar='DIR')

	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(args)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)

	if options.version:
		from zeroinstall.gui import gui
		print("0launch-gui (zero-install) " + gui.version)
		print("Copyright (C) 2010 Thomas Leonard")
		print(_("This program comes with ABSOLUTELY NO WARRANTY,"
				"\nto the extent permitted by law."
				"\nYou may redistribute copies of this program"
				"\nunder the terms of the GNU Lesser General Public License."
				"\nFor more information about these matters, see the file named COPYING."))
		sys.exit(0)

	if not gui_is_available(options.force_gui):
		sys.exit(100)
	from zeroinstall.gui import gui

	handler = gui.GUIHandler()

	config = load_config(handler)

	assert len(args) > 0

	interface_uri = args[0]

	if len(args) > 1:
		parser.print_help()
		sys.exit(1)

	from zeroinstall.gui import mainwindow, dialog

	widgets = dialog.Template('main')

	root_iface = config.iface_cache.get_interface(interface_uri)

	finished = tasks.Blocker("GUI finished")

	def resolve(result):
		finished.gui_result = result
		finished.trigger()

	driver = OCamlDriver(config)

	window = mainwindow.MainWindow(driver, widgets, download_only = bool(options.download_only), resolve = resolve, select_only = bool(options.select_only))
	handler.mainwindow = window

	if options.message:
		window.set_message(options.message)

	window.window.connect('destroy', lambda w: handler.abort_all_downloads())

	if options.systray:
		window.use_systray_icon(root_iface)

	logger = logging.getLogger()

	def prepare_for_recalc(force_refresh):
		window.refresh_button.set_sensitive(False)
		window.browser.set_update_icons(force_refresh)
		if not window.systray_icon:
			window.show()

	force_refresh = bool(options.refresh)
	prepare_for_recalc(force_refresh)

	# Called each time a complete solve_with_downloads is done.
	@tasks.async
	def run_gui(reply_holder):
		window.refresh_button.set_sensitive(True)
		window.browser.highlight_problems()

		if window.systray_icon and window.systray_icon.get_visible() and \
		   window.systray_icon.is_embedded():
			if driver.ready:
				window.systray_icon.set_tooltip(_('Downloading updates for %s') % root_iface.get_name())
				window.run_button.set_active(True)
			else:
				# Should already be reporting an error, but
				# blink it again just in case
				window.systray_icon.set_blinking(True)

		refresh_clicked = dialog.ButtonClickedBlocker(window.refresh_button)
		yield refresh_clicked, _recalculate, finished

		if finished.happened:
			reply_holder.append([finished.gui_result])
		else:
			reply_holder.append(["recalculate", refresh_clicked.happened])

		prepare_for_recalc(refresh_clicked.happened)

	return (run_gui, driver)
