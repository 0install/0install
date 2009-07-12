"""Loading icons."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import gtk
from logging import warn

def load_icon(icon_path):
	"""Load icon from path. Icon MUST be in PNG format.
	@param icon_path: pathname of icon, or None to load nothing
	@return: a GdkPixbuf, or None on failure"""
	if not icon_path:
		return None
	try:
		# Icon format must be PNG (to avoid attacks)
		loader = gtk.gdk.PixbufLoader('png')
		try:
			loader.write(file(icon_path).read())
		finally:
			loader.close()
		return loader.get_pixbuf()
	except Exception, ex:
		warn(_("Failed to load cached PNG icon: %s") % ex)
		return None
