"""Useful utility methods for GTK."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
import sys
from zeroinstall.support import tasks
from zeroinstall import _

class Template(object):
	"""Wrapper for GtkBuilder widget tree that throws a sensible exception if the widget isn't found."""
	def __init__(self, builderfile, root):
		"""Constructor.
		@param builderfile: pathname of the .ui file to load
		@param root: the name of the top-level widget inside the file"""
		self.builder = gtk.Builder()
		self.builder.set_translation_domain('zero-install')
		self.builder.add_from_file(builderfile)
		self.builderfile = builderfile
		self.root = root

	def get_widget(self, name = None):
		"""Look up a widget by name."""
		if not name:
			name = self.root
		widget = self.builder.get_object(name)
		assert widget, "Widget '%s' not found in GtkBuilder file '%s'" % (name, self.builderfile)
		return widget

def show_message_box(parent, message, type = gtk.MESSAGE_ERROR):
	"""Display a non-modal message box with an OK button.
	@param parent: the parent window
	@param message: the message to be displayed
	@param type: the type of box (used for the icon)"""
	box = gtk.MessageDialog(parent, gtk.DIALOG_DESTROY_WITH_PARENT,
				type, gtk.BUTTONS_OK,
				str(message))
	box.set_position(gtk.WIN_POS_CENTER)
	def resp(b, r):
		b.destroy()
	box.connect('response', resp)
	box.show()

_busy_pointer = None
def get_busy_pointer():
	"""Get a GDK background-activity cursor.
	Use this when something is happening, but the GUI is still responsive.
	@return: the busy cursor (a singleton)
	@rtype: gdk.Cursor
	"""
	global _busy_pointer
	if _busy_pointer is not None:
		return _busy_pointer

	# This is crazy. We build a cursor that looks like the old
	# Netscape busy-with-a-pointer cursor and set that, then the
	# X server replaces it with a decent-looking one!!
	# See http://mail.gnome.org/archives/gtk-list/2007-May/msg00100.html

	bit_data = "\
\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\
\x0c\x00\x00\x00\x1c\x00\x00\x00\x3c\x00\x00\x00\
\x7c\x00\x00\x00\xfc\x00\x00\x00\xfc\x01\x00\x00\
\xfc\x3b\x00\x00\x7c\x38\x00\x00\x6c\x54\x00\x00\
\xc4\xdc\x00\x00\xc0\x44\x00\x00\x80\x39\x00\x00\
\x80\x39\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
\x00\x00\x00\x00\x00\x00\x00\x00"

	try:
		pix = gtk.gdk.bitmap_create_from_data(None, bit_data, 32, 32)
		color = gtk.gdk.Color()
		_busy_pointer = gtk.gdk.Cursor(pix, pix, color, color, 2, 2)
	except:
		#old bug http://bugzilla.gnome.org/show_bug.cgi?id=103616
		_busy_pointer = gtk.gdk.Cursor(gtk.gdk.WATCH)
	return _busy_pointer

class DialogResponse(tasks.Blocker):
	"""Triggers when the GtkDialog gets a response.
	@since: 1.5"""
	response = None
	def __init__(self, dialog):
		tasks.Blocker.__init__(self, dialog.get_title())
		a = None
		def response(d, resp, self = self):	# (PyGTK GC bug)
			self.response = resp
			d.disconnect(a)
			self.trigger()
		a = dialog.connect('response', response)

class ButtonClickedBlocker(tasks.Blocker):
	"""Triggers when the GtkButton is activated.
	@since: 1.5"""
	def __init__(self, button):
		tasks.Blocker.__init__(self, "Button click")
		a = None
		def clicked(b):
			b.disconnect(a)
			self.trigger()
		a = button.connect('clicked', lambda b: self.trigger())

def MixedButton(message, stock, x_align = 0.5, button = None):
	"""A GtkButton with a stock icon.
	@since: 1.5"""
	if button is None:
		button = gtk.Button()

	label = gtk.Label('')
	label.set_text_with_mnemonic(message)
	label.set_mnemonic_widget(button)

	image = gtk.image_new_from_stock(stock, gtk.ICON_SIZE_BUTTON)
	box = gtk.HBox()
	box.set_homogeneous(False)
	box.set_spacing(2)
	align = gtk.Alignment(x_align, 0.5, 0.0, 0.0)

	box.pack_start(image, False, False, 0)
	box.pack_end(label, False, False, 0)

	button.add(align)
	align.add(box)
	return button

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
