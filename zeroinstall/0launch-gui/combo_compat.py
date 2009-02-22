# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, gobject

class Action(gobject.GObject):
	__proxy = None
	__sensitive = True

	__gproperties__ = {
          'sensitive' : (gobject.TYPE_BOOLEAN,		# type
                    'sensitive',                        # nick name
                    'sensitive', 			# description
                    True,                               # default value
                    gobject.PARAM_READWRITE)            # flags
	}

	__gsignals__ = {
	  'activate' : (gobject.SIGNAL_RUN_LAST, gobject.TYPE_NONE, ())
	}

	def __init__(self, name, label, tooltip, stock_id):
		gobject.GObject.__init__(self)
	
	def do_get_property(self, property):
		return getattr(self, property.name)

	def do_set_property(self, property, value):
		setattr(self, property.name, value)
	
	def connect_proxy(self, widget):
		assert self.__proxy is None
		self.__proxy = widget
		self.sensitive = self.__sensitive
		widget.connect('clicked', lambda w: self.emit('activate'))

	def set_sensitive(self, value):
		if self.__proxy:
			self.__proxy.set_sensitive(value)
		self.__sensitive = value
	
	sensitive = property(lambda self: self.__sensitive, set_sensitive)

gobject.type_register(Action)

class ComboText(gtk.OptionMenu):
	def __init__(self):
		gtk.OptionMenu.__init__(self)
		self.__menu = gtk.Menu()
		self.__model = []
		self.set_menu(self.__menu)

	def append_text(self, text):
		item = gtk.MenuItem(text)
		self.__model.append([text])
		self.__menu.append(item)

	def set_active(self, i):
		self.set_history(i)
	
	def get_active(self):
		return self.get_history()
	
	def get_model(self):
		return self.__model

def combo_box_new_text():
	return ComboText()

gtk.combo_box_new_text = combo_box_new_text
gtk.Action = Action
