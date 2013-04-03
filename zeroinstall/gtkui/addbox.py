"""A GTK dialog which lets the user add a new application to their desktop."""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, gobject
import os
import gtk
from zeroinstall.gtkui import gtkutils

from zeroinstall import SafeException
from zeroinstall.injector import model
from zeroinstall.injector.namespaces import XMLNS_IFACE
from zeroinstall.injector.iface_cache import iface_cache

_RESPONSE_PREV = 0
_RESPONSE_NEXT = 1

def N_(message): return message

categories = [
	N_('AudioVideo'),
	N_('Audio'),
	N_('Video'),
	N_('Development'),
	N_('Education'),
	N_('Game'),
	N_('Graphics'),
	N_('Network'),
	N_('Office'),
	N_('Settings'),
	N_('System'),
	N_('Utility'),
	]

class AddBox(object):
	"""A dialog box which prompts the user to choose the program to be added."""
	def __init__(self, interface_uri = None):
		builderfile = os.path.join(os.path.dirname(__file__), 'desktop.ui')

		builder = gtk.Builder()
		builder.set_translation_domain('zero-install')
		builder.add_from_file(builderfile)
		self.window = builder.get_object('main')
		self.set_keep_above(True)

		def set_uri_ok(uri):
			text = uri.get_text()
			self.window.set_response_sensitive(_RESPONSE_NEXT, bool(text))

		uri = builder.get_object('interface_uri')
		about = builder.get_object('about')
		icon_widget = builder.get_object('icon')
		category = builder.get_object('category')
		dialog_next = builder.get_object('dialog_next')
		dialog_ok = builder.get_object('dialog_ok')

		if interface_uri:
			uri.set_text(interface_uri)

		uri.connect('changed', set_uri_ok)
		set_uri_ok(uri)

		for c in categories:
			category.append_text(_(c))
		category.set_active(11)

		def uri_dropped(iface):
			if not gtkutils.sanity_check_iface(self.window, iface):
				return False
			uri.set_text(iface)
			self.window.response(_RESPONSE_NEXT)
			print("ok")
			return True
		gtkutils.make_iface_uri_drop_target(self.window, uri_dropped)

		nb = builder.get_object('notebook1')

		def update_details_page():
			iface_uri = model.canonical_iface_uri(uri.get_text())
			iface = iface_cache.get_interface(iface_uri)
			feed = iface_cache.get_feed(iface_uri)
			assert feed, iface_uri
			about.set_text('%s - %s' % (feed.get_name(), feed.summary))
			icon_path = iface_cache.get_icon_path(iface)
			from zeroinstall.gtkui import icon
			icon_pixbuf = icon.load_icon(icon_path)
			if icon_pixbuf:
				icon_widget.set_from_pixbuf(icon_pixbuf)

			feed_category = None
			for meta in feed.get_metadata(XMLNS_IFACE, 'category'):
				feed_category = meta.content
				break
			if feed_category:
				i = 0
				for row in categories:
					if row.lower() == feed_category.lower():
						category.set_active(i)
						break
					i += 1
			self.window.set_response_sensitive(_RESPONSE_PREV, True)

		def finish():
			from . import xdgutils
			iface_uri = model.canonical_iface_uri(uri.get_text())
			iface = iface_cache.get_interface(iface_uri)
			feed = iface_cache.get_feed(iface_uri)

			try:
				icon_path = iface_cache.get_icon_path(iface)
				xdgutils.add_to_menu(feed, icon_path, categories[category.get_active()])
			except SafeException as ex:
				box = gtk.MessageDialog(self.window, gtk.DIALOG_MODAL, gtk.MESSAGE_ERROR, gtk.BUTTONS_OK, str(ex))
				box.run()
				box.destroy()
			else:
				self.window.destroy()

		def response(box, resp):
			if resp == _RESPONSE_NEXT:
				iface = uri.get_text()
				if not gtkutils.sanity_check_iface(self.window, iface):
					return
				self.window.set_sensitive(False)
				self.set_keep_above(False)
				import subprocess
				child = subprocess.Popen(['0launch',
						  '--gui', '--download-only',
						  '--', iface],
						  stdout = subprocess.PIPE,
						  stderr = subprocess.STDOUT)
				errors = [b'']
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
								_('Failed to run 0launch.\n') + errors[0].decode('utf-8'))
							box.run()
							box.destroy()
						return False
					return True
				gobject.io_add_watch(child.stdout,
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

		if interface_uri:
			self.window.response(_RESPONSE_NEXT)

	def set_keep_above(self, above):
		if hasattr(self.window, 'set_keep_above'):
			# This isn't very nice, but GNOME defaults to
			# click-to-raise and in that mode drag-and-drop
			# is useless without this...
			self.window.set_keep_above(above)
