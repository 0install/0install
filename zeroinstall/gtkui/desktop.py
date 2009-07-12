"""Code for the B{0desktop} command."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import sys
from optparse import OptionParser
import logging

def main(command_args):
	"""Implements the logic of the 0desktop command.
	@param command_args: the command-line arguments"""
	parser = OptionParser(usage=_("usage: %prog [options] [URI]"))
	parser.add_option("-m", "--manage", help=_("manage added applications"), action='store_true')
	parser.add_option("-v", "--verbose", help=_("more verbose output"), action='count')
	parser.add_option("-V", "--version", help=_("display version information"), action='store_true')

	(options, args) = parser.parse_args(command_args)

	if options.verbose:
		logger = logging.getLogger()
		if options.verbose == 1:
			logger.setLevel(logging.INFO)
		else:
			logger.setLevel(logging.DEBUG)
		hdlr = logging.StreamHandler()
		fmt = logging.Formatter("%(levelname)s:%(message)s")
		hdlr.setFormatter(fmt)
		logger.addHandler(hdlr)

	if options.version:
		import zeroinstall
		print "0desktop (zero-install) " + zeroinstall.version
		print "Copyright (C) 2009 Thomas Leonard"
		print _("This program comes with ABSOLUTELY NO WARRANTY,"
				"\nto the extent permitted by law."
				"\nYou may redistribute copies of this program"
				"\nunder the terms of the GNU Lesser General Public License."
				"\nFor more information about these matters, see the file named COPYING.")
		sys.exit(0)

	if not args:
		interface_uri = None
	elif len(args) == 1:
		interface_uri = args[0]
	else:
		parser.print_help()
		sys.exit(1)

	import pygtk; pygtk.require('2.0')
	import gtk

	if options.manage:
		from zeroinstall.gtkui.applistbox import AppListBox, AppList
		from zeroinstall.injector.iface_cache import iface_cache
		box = AppListBox(iface_cache, AppList())
	else:
		from zeroinstall.gtkui.addbox import AddBox
		box = AddBox(interface_uri)

	box.window.connect('destroy', gtk.main_quit)
	box.window.show()
	gtk.main()
