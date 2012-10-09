# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os, sys
import logging
import warnings

from optparse import OptionParser

from zeroinstall import _, SafeException
from zeroinstall.injector import requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.injector.config import load_config
from zeroinstall.support import tasks

_recalculate = tasks.Blocker('recalculate')

def recalculate():
	"""Ask the mainloop to recalculate. If we're already recalculating, wait for that to finish
	and then do it again."""
	global _recalculate
	_recalculate.trigger()
	_recalculate = tasks.Blocker('recalculate')

def run_gui(args):
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
		import gui
		print("0launch-gui (zero-install) " + gui.version)
		print("Copyright (C) 2010 Thomas Leonard")
		print(_("This program comes with ABSOLUTELY NO WARRANTY,"
				"\nto the extent permitted by law."
				"\nYou may redistribute copies of this program"
				"\nunder the terms of the GNU Lesser General Public License."
				"\nFor more information about these matters, see the file named COPYING."))
		sys.exit(0)

	def nogui(ex):
		if options.force_gui:
			fn = logging.warn
		else:
			fn = logging.info
			fn("No GUI available", exc_info = ex)
		sys.exit(100)

	with warnings.catch_warnings():
		if not options.force_gui:
			warnings.filterwarnings("ignore")
		if sys.version_info[0] < 3:
			try:
				import pygtk; pygtk.require('2.0')
			except ImportError as ex:
				nogui(ex)

		import gui

		try:
			if sys.version_info[0] > 2:
				from zeroinstall.gtkui import pygtkcompat
				pygtkcompat.enable()
				pygtkcompat.enable_gtk(version = '3.0')
			import gtk
		except (ImportError, ValueError, RuntimeError) as ex:
			nogui(ex)

		if gtk.gdk.get_display() is None:
			try:
				raise SafeException("Failed to connect to display.")
			except SafeException as ex:
				nogui(ex)	# logging needs this as a raised exception

	handler = gui.GUIHandler()

	config = load_config(handler)

	if options.with_store:
		from zeroinstall import zerostore
		for x in options.with_store:
			config.stores.stores.append(zerostore.Store(os.path.abspath(x)))

	if len(args) < 1:
		@tasks.async
		def prefs_main():
			import preferences
			box = preferences.show_preferences(config)
			done = tasks.Blocker('close preferences')
			box.connect('destroy', lambda w: done.trigger())
			yield done
		tasks.wait_for_blocker(prefs_main())
		sys.exit(0)

	interface_uri = args[0]

	if len(args) > 1:
		parser.print_help()
		sys.exit(1)

	import mainwindow, dialog

	r = requirements.Requirements(interface_uri)
	r.parse_options(options)

	widgets = dialog.Template('main')

	driver = Driver(config = config, requirements = r)
	root_iface = config.iface_cache.get_interface(interface_uri)
	driver.solver.record_details = True

	window = mainwindow.MainWindow(driver, widgets, download_only = bool(options.download_only), select_only = bool(options.select_only))
	handler.mainwindow = window

	if options.message:
		window.set_message(options.message)

	root = config.iface_cache.get_interface(r.interface_uri)
	window.browser.set_root(root)

	window.window.connect('destroy', lambda w: handler.abort_all_downloads())

	if options.systray:
		window.use_systray_icon()

	@tasks.async
	def main():
		force_refresh = bool(options.refresh)
		while True:
			window.refresh_button.set_sensitive(False)
			window.browser.set_update_icons(force_refresh)

			solved = driver.solve_with_downloads(force = force_refresh, update_local = True)

			if not window.systray_icon:
				window.show()
			yield solved
			try:
				window.refresh_button.set_sensitive(True)
				window.browser.highlight_problems()
				tasks.check(solved)
			except Exception as ex:
				window.report_exception(ex)

			if window.systray_icon and window.systray_icon.get_visible() and \
			   window.systray_icon.is_embedded():
				if driver.solver.ready:
					window.systray_icon.set_tooltip(_('Downloading updates for %s') % root_iface.get_name())
					window.run_button.set_active(True)
				else:
					# Should already be reporting an error, but
					# blink it again just in case
					window.systray_icon.set_blinking(True)

			refresh_clicked = dialog.ButtonClickedBlocker(window.refresh_button)
			yield refresh_clicked, _recalculate

			if refresh_clicked.happened:
				force_refresh = True

	tasks.wait_for_blocker(main())
