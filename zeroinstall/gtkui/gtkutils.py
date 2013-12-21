"""Useful utility methods for GTK."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
import sys
from zeroinstall import _

def sanity_check_iface(window, uri):
	if uri.endswith('.tar.bz2') or \
	   uri.endswith('.tar.gz') or \
	   uri.endswith('.exe') or \
	   uri.endswith('.rpm') or \
	   uri.endswith('.deb') or \
	   uri.endswith('.tgz'):
		box = gtk.MessageDialog(window, gtk.DIALOG_MODAL, gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
			_("This URI (%s) looks like an archive, not a Zero Install feed. Make sure you're using the feed link!") % uri)
		box.run()
		box.destroy()
		return False
	return True

def make_iface_uri_drop_target(window, on_success):
	"""When a URI is dropped on 'window', call on_success(uri).
	If it returns True, accept the drop."""
	_URI_LIST = 0
	_UTF_16 = 1

	def uri_dropped(eb, drag_context, x, y, selection_data, info, timestamp):
		uris = selection_data.get_uris()
		if uris:
			assert len(uris) == 1, uris
			data, = uris
		else:
			if info == _UTF_16:
				import codecs
				data = codecs.getdecoder('utf16')(selection_data.get_data())[0]
				data = data.split('\n', 1)[0].strip()
			else:
				data = selection_data.get_text().split('\n', 1)[0].strip()
		if on_success(data):
			drag_context.finish(True, False, timestamp)
		return True
	if sys.version_info[0] < 3:
		def TargetEntry(*args): return args
	else:
		TargetEntry = gtk.TargetEntry.new
	window.drag_dest_set(gtk.DEST_DEFAULT_MOTION | gtk.DEST_DEFAULT_DROP | gtk.DEST_DEFAULT_HIGHLIGHT,
				[TargetEntry('text/uri-list', 0, _URI_LIST),
				 TargetEntry('text/x-moz-url', 0, _UTF_16)],
				gtk.gdk.ACTION_COPY)
	window.drag_dest_add_uri_targets()	# Needed for GTK 3
	window.connect('drag-data-received', uri_dropped)
