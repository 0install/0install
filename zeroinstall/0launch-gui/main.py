# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys

from optparse import OptionParser

from zeroinstall.injector import model, arch
from zeroinstall.injector.policy import Policy
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.support import tasks

def run_gui(args):
	parser = OptionParser(usage="usage: %prog [options] interface")
	parser.add_option("", "--before", help="choose a version before this", metavar='VERSION')
	parser.add_option("", "--cpu", help="target CPU type", metavar='CPU')
	parser.add_option("-c", "--cache", help="show the cache", action='store_true')
	parser.add_option("-d", "--download-only", help="fetch but don't run", action='store_true')
	parser.add_option("", "--not-before", help="minimum version to choose", metavar='VERSION')
	parser.add_option("", "--os", help="target operation system type", metavar='OS')
	parser.add_option("-r", "--refresh", help="check for updates of all interfaces", action='store_true')
	parser.add_option("-s", "--source", help="select source code", action='store_true')
	parser.add_option("-v", "--verbose", help="more verbose output", action='count')
	parser.add_option("-V", "--version", help="display version information", action='store_true')

	parser.disable_interspersed_args()

	(options, args) = parser.parse_args(args)

	if options.verbose:
		import logging
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)

	if options.cache:
		# Must fork before importing gtk, or ATK dies
		if os.fork():
			# We exit, so our parent can call waitpid and unblock.
			sys.exit(0)
		# The grandchild continues...

	import gui

	if options.version:
		print "0launch-gui (zero-install) " + gui.version
		print "Copyright (C) 2007 Thomas Leonard"
		print "This program comes with ABSOLUTELY NO WARRANTY,"
		print "to the extent permitted by law."
		print "You may redistribute copies of this program"
		print "under the terms of the GNU General Public License."
		print "For more information about these matters, see the file named COPYING."
		sys.exit(0)

	import gtk
	if gtk.gdk.get_display() is None:
		print >>sys.stderr, "Failed to connect to display. Aborting."
		sys.exit(1)

	if not hasattr(gtk, 'combo_box_new_text'):
		import combo_compat

	if options.cache:
		import cache
		cache_explorer = cache.CacheExplorer()
		cache_explorer.show()
		cache_explorer.window.set_cursor(gtk.gdk.Cursor(gtk.gdk.WATCH))
		gtk.gdk.flush()
		cache_explorer.populate_model()
		cache_explorer.window.set_cursor(None)
		gtk.main()
		sys.exit(0)

	if len(args) < 1:
		parser.print_help()
		sys.exit(1)

	interface_uri = args[0]

	if len(args) > 1:
		parser.print_help()
		sys.exit(1)

	import mainwindow, dialog

	restrictions = []
	if options.before or options.not_before:
		restrictions.append(model.VersionRangeRestriction(model.parse_version(options.before),
								  model.parse_version(options.not_before)))

	widgets = dialog.Template('main')

	handler = gui.GUIHandler()
	policy = Policy(interface_uri, handler, src = bool(options.source))
	policy.target_arch = arch.get_architecture(options.os, options.cpu)
	root_iface = iface_cache.get_interface(interface_uri)
	policy.solver.extra_restrictions[root_iface] = restrictions
	policy.solver.record_details = True

	window = mainwindow.MainWindow(policy, widgets, download_only = bool(options.download_only))
	handler.mainwindow = window

	root = iface_cache.get_interface(policy.root)
	window.browser.set_root(root)

	window.window.connect('destroy', lambda w: handler.abort_all_downloads())

	@tasks.async
	def main():
		force_refresh = bool(options.refresh)
		while True:
			window.refresh_button.set_sensitive(False)

			solved = policy.solve_with_downloads(force = force_refresh)

			window.show()
			yield solved
			try:
				window.refresh_button.set_sensitive(True)
				tasks.check(solved)
			except model.SafeException, ex:
				dialog.alert(window.window, str(ex))
			except Exception, ex:
				import traceback
				traceback.print_exc()
				dialog.alert(window.window, str(ex))

			yield dialog.ButtonClickedBlocker(window.refresh_button)
			force_refresh = True

	handler.wait_for_blocker(main())
