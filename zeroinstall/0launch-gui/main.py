# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys

from optparse import OptionParser

from zeroinstall.injector import requirements
from zeroinstall.injector.policy import Policy, load_config
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
	parser.add_option("", "--message", help=_("message to display when interacting with user"))
	parser.add_option("", "--not-before", help=_("minimum version to choose"), metavar='VERSION')
	parser.add_option("", "--os", help=_("target operation system type"), metavar='OS')
	parser.add_option("-r", "--refresh", help=_("check for updates of all interfaces"), action='store_true')
	parser.add_option("", "--select-only", help=_("only download the feeds"), action='store_true')
	parser.add_option("-s", "--source", help=_("select source code"), action='store_true')
	parser.add_option("", "--systray", help=_("download in the background"), action='store_true')
	parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
	parser.add_option("-V", "--version", help=_("display version information"), action='store_true')
	parser.add_option("", "--with-store", help=_("add an implementation cache"), action='append', metavar='DIR')

	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(args)

	if options.verbose:
		import logging
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)

	import gui

	if options.version:
		print "0launch-gui (zero-install) " + gui.version
		print "Copyright (C) 2010 Thomas Leonard"
		print _("This program comes with ABSOLUTELY NO WARRANTY,"
				"\nto the extent permitted by law."
				"\nYou may redistribute copies of this program"
				"\nunder the terms of the GNU Lesser General Public License."
				"\nFor more information about these matters, see the file named COPYING.")
		sys.exit(0)

	import gtk
	if gtk.gdk.get_display() is None:
		print >>sys.stderr, "Failed to connect to display. Aborting."
		sys.exit(1)

	handler = gui.GUIHandler()

	config = load_config(handler)

	if options.with_store:
		from zeroinstall import zerostore
		for x in options.with_store:
			config.stores.stores.append(zerostore.Store(os.path.abspath(x)))

	if len(args) < 1:
		import preferences
		box = preferences.show_preferences(config)
		box.connect('destroy', gtk.main_quit)
		gtk.main()
		sys.exit(0)

	interface_uri = args[0]

	if len(args) > 1:
		parser.print_help()
		sys.exit(1)

	import mainwindow, dialog

	r = requirements.Requirements(interface_uri)
	r.parse_options(options)

	widgets = dialog.Template('main')

	policy = Policy(config = config, requirements = r)
	root_iface = config.iface_cache.get_interface(interface_uri)
	policy.solver.record_details = True

	window = mainwindow.MainWindow(policy, widgets, download_only = bool(options.download_only), select_only = bool(options.select_only))
	handler.mainwindow = window

	if options.message:
		window.set_message(options.message)

	root = config.iface_cache.get_interface(policy.root)
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

			solved = policy.solve_with_downloads(force = force_refresh, update_local = True)

			if not window.systray_icon:
				window.show()
			yield solved
			try:
				window.refresh_button.set_sensitive(True)
				tasks.check(solved)
			except Exception, ex:
				window.report_exception(ex)

			if window.systray_icon and window.systray_icon.get_visible() and \
			   window.systray_icon.is_embedded():
				if policy.ready:
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

	handler.wait_for_blocker(main())
