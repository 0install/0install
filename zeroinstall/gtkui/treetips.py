"""Add tooltips to a TreeView."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import time, gobject, gtk

class TreeTips:
	"""This object allows you to set location-dependent tooltips on a TreeView.
	Connect your TreeView's leave-notify-event to the L{hide} method.
	In your motion-notify-event handler, call L{prime} when the pointer moves
	to an area with a new message. The message will be shown after a delay.
	If calculation of the message is expensive, override L{get_tooltip_text}
	instead.
	"""
	timeout = None
	widget = None
	item = None
	time = 0

	def show(self, parent):
		if self.timeout:
			gobject.source_remove(self.timeout)
			self.timeout = None

		if self.widget:
			self.widget.destroy()
			self.widget = None

		if self.item is None:
			return

		text = self.get_tooltip_text()
		if not text:
			return

		self.widget = gtk.Window(gtk.WINDOW_POPUP)
		self.widget.set_app_paintable(True)
		self.widget.set_name('gtk-tooltips')

		self.widget.connect('expose-event', self.tooltip_draw)

		label = gtk.Label(text)
		label.set_line_wrap(True)
		label.set_padding(4, 2)
		self.widget.add(label)
		label.show()

		w, h = self.widget.size_request()
		if hasattr(parent, 'get_screen'):
			screen = parent.get_screen()
			root = screen.get_root_window()
		else:
			root = gtk.gdk.get_default_root_window()
		px, py, mask = gtk.gdk.Window.get_pointer(root)

		#m = gtk.gdk.screen_get_default().get_monitor_at_point(px, py)
		
		x = px - w / 2
		y = py + 12

		# Test if pointer is over the tooltip window
		if py >= y and py <= y + h:
			y = py - h - 2
		self.widget.move(x, y)
		self.widget.show()

		self.widget.connect('destroy', self.tooltip_destroyed)
		self.time = time.time()
	
	def prime(self, parent, item):
		"""Call this whenever the pointer moves to an area with a different
		tooltip.
		@param parent: the TreeView widget
		@param item: the text to display
		@see L{get_tooltip_text}"""
		self.hide()
		assert self.timeout is None
		self.item = item
	
		now = time.time()
		if now - self.time > 2:
			delay = 1000
		else:
			delay = 100

		self.timeout = gobject.timeout_add(delay, lambda: self.show(parent))

	def tooltip_draw(self, widget, ev):
		widget.window.draw_rectangle(widget.style.fg_gc[widget.state],
					False, 0, 0,
					widget.allocation.width - 1,
					widget.allocation.height - 1)

	def tooltip_destroyed(self, widget):
		pass
	
	def hide(self):
		"""Hide the tooltip, if any.
		Sets L{item} to None."""
		self.item = None
		self.show(None)
	
	def get_tooltip_text(self):
		""""Converts the object passed to L{prime} to a string for display.
		The default implementation just calls C{str}, but subclasses can override it.
		@return: the tooltip message"""
		return str(self.item)
