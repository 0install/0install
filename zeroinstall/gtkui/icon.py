"""Loading icons."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import gtk
from logging import warn
import math

def load_icon(icon_path, icon_width=None, icon_height=None):
	"""Load icon from path. Icon MUST be in PNG format.
	@param icon_path: pathname of icon, or None to load nothing
	@return: a GdkPixbuf, or None on failure"""
	if not icon_path:
		return None

	def size_prepared_cb(loader, width, height):
		dest_width = icon_width or width
		dest_height = icon_height or height

		if dest_width == width and dest_height == height:
			return

		ratio_width = float(dest_width) / width
		ratio_height = float(dest_height) / height
		ratio = min(ratio_width, ratio_height)

		# preserve original ration
		if ratio_width != ratio:
			dest_width = int(math.ceil(width * ratio))
		elif ratio_height != ratio:
			dest_height = int(math.ceil(height * ratio))

		loader.set_size(int(dest_width), int(dest_height))

	# Restrict icon formats to avoid attacks
	try:
		loader = gtk.gdk.PixbufLoader('png')
		if icon_width or icon_height:
			loader.connect('size-prepared', size_prepared_cb)
		try:
			loader.write(file(icon_path).read())
		finally:
			loader.close()
		return loader.get_pixbuf()
	except Exception, ex:
		warn(_("Failed to load cached PNG icon: %s") % ex)
		return None
