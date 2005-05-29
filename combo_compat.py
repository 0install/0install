import gtk, gobject

class Action(gobject.GObject):
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
		return setattr(self, property.name, value)
	
	def connect_proxy(self, widget):
		print "connect_proxy", widget

gobject.type_register(Action)

class ComboText(gtk.OptionMenu):
	def __init__(self):
		gtk.OptionMenu.__init__(self)
		self.__menu = gtk.Menu()
		self.set_menu(self.__menu)

	def append_text(self, text):
		item = gtk.MenuItem(text)
		self.__menu.append(item)

	def set_active(self, i):
		self.set_history(i)
	
	def get_active(self):
		return self.get_history()

def combo_box_new_text():
	return ComboText()

gtk.combo_box_new_text = combo_box_new_text
gtk.Action = Action
