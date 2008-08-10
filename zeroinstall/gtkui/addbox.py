"""A GTK dialog which lets the user add a new application to their desktop."""
# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys
import gtk, gobject
import gtk.glade

from zeroinstall import SafeException
from zeroinstall.injector import model
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.iface_cache import iface_cache

_URI_LIST = 0
_UTF_16 = 1

_RESPONSE_PREV = 0
_RESPONSE_NEXT = 1

class AddBox:
	"""A dialog box which prompts the user to choose the program to be added."""
	def __init__(self, interface_uri = None):
		gladefile = os.path.join(os.path.dirname(__file__), 'desktop.glade')

		widgets = gtk.glade.XML(gladefile, 'main')
		self.window = widgets.get_widget('main')
		self.set_keep_above(True)

		def set_uri_ok(uri):
			text = uri.get_text()
			self.window.set_response_sensitive(_RESPONSE_NEXT, bool(text))

		uri = widgets.get_widget('interface_uri')
		about = widgets.get_widget('about')
		icon_widget = widgets.get_widget('icon')
		category = widgets.get_widget('category')
		dialog_next = widgets.get_widget('dialog_next')
		dialog_ok = widgets.get_widget('dialog_ok')

		if interface_uri:
			uri.set_text(interface_uri)

		uri.connect('changed', set_uri_ok)
		set_uri_ok(uri)

		category.set_active(11)

		def uri_dropped(eb, drag_context, x, y, selection_data, info, timestamp):
			if info == _UTF_16:
				import codecs
				data = codecs.getdecoder('utf16')(selection_data.data)[0]
				data = data.split('\n', 1)[0].strip()
			else:
				data = selection_data.data.split('\n', 1)[0].strip()
			uri.set_text(data)
			drag_context.finish(True, False, timestamp)
			self.window.response(_RESPONSE_NEXT)
			return True
		self.window.drag_dest_set(gtk.DEST_DEFAULT_MOTION | gtk.DEST_DEFAULT_DROP | gtk.DEST_DEFAULT_HIGHLIGHT,
					[('text/uri-list', 0, _URI_LIST),
					 ('text/x-moz-url', 0, _UTF_16)],
					gtk.gdk.ACTION_COPY)
		self.window.connect('drag-data-received', uri_dropped)

		nb = widgets.get_widget('notebook1')

		def update_details_page():
			iface = iface_cache.get_interface(model.canonical_iface_uri(uri.get_text()))
			about.set_text('%s - %s' % (iface.get_name(), iface.summary))
			icon_path = iface_cache.get_icon_path(iface)
			from zeroinstall.gtkui import icon
			icon_pixbuf = icon.load_icon(icon_path)
			if icon_pixbuf:
				icon_widget.set_from_pixbuf(icon_pixbuf)

			feed_category = None
			for meta in iface.get_metadata(XMLNS_IFACE, 'category'):
				feed_category = meta.content
				break
			if feed_category:
				i = 0
				for row in category.get_model():
					if row[0].lower() == feed_category.lower():
						category.set_active(i)
						break
					i += 1
			self.window.set_response_sensitive(_RESPONSE_PREV, True)

		def finish():
			import xdgutils
			iface = iface_cache.get_interface(model.canonical_iface_uri(uri.get_text()))

			try:
				icon_path = iface_cache.get_icon_path(iface)
				xdgutils.add_to_menu(iface, icon_path, category.get_active_text())
			except SafeException, ex:
				box = gtk.MessageDialog(self.window, gtk.DIALOG_MODAL, gtk.MESSAGE_ERROR, gtk.BUTTONS_OK, str(ex))
				box.run()
				box.destroy()
			else:
				self.window.destroy()

		def response(box, resp):
			if resp == _RESPONSE_NEXT:
				iface = uri.get_text()
				self.window.set_sensitive(False)
				self.set_keep_above(False)
				import popen2
				child = popen2.Popen4(['0launch',
						  '--gui', '--download-only',
						  '--', iface])
				child.tochild.close()
				errors = ['']
				def output_ready(src, cond):
					got = os.read(src.fileno(), 100)
					if got:
						errors[0] += got
					else:
						status = child.wait()
						self.window.set_sensitive(True)
						self.set_keep_above(True)
						if status == 0:
							update_details_page()
							nb.next_page()
							dialog_next.set_property('visible', False)
							dialog_ok.set_property('visible', True)
							dialog_ok.grab_focus()
						else:
							box = gtk.MessageDialog(self.window, gtk.DIALOG_MODAL, gtk.MESSAGE_ERROR, gtk.BUTTONS_OK,
								'Failed to run 0launch.\n' + errors[0])
							box.run()
							box.destroy()
						return False
					return True
				gobject.io_add_watch(child.fromchild,
							   gobject.IO_IN | gobject.IO_HUP,
							   output_ready)
			elif resp == gtk.RESPONSE_OK:
				finish()
			elif resp == _RESPONSE_PREV:
				dialog_next.set_property('visible', True)
				dialog_ok.set_property('visible', False)
				dialog_next.grab_focus()
				nb.prev_page()
				self.window.set_response_sensitive(_RESPONSE_PREV, False)
			else:
				box.destroy()
		self.window.connect('response', response)

		if len(sys.argv) > 1:
			self.window.response(_RESPONSE_NEXT)

	def set_keep_above(self, above):
		if hasattr(self.window, 'set_keep_above'):
			# This isn't very nice, but GNOME defaults to
			# click-to-raise and in that mode drag-and-drop
			# is useless without this...
			self.window.set_keep_above(above)
