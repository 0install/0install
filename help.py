import gtk

message = """<big>Injector Help</big>

<u>Overview</u>
A program is made up of many different components, typically written by different
groups of people. Each component is available in multiple versions. The injector is
used when starting a program. It's job is to decide which version of each required
component to use.

An <i>interface</i> describes what a component does. The injector starts with
the interface for the program you want to run (like 'The Gimp') and chooses an
<i>implementation</i> (like 'The Gimp 2.2.0').  However, this implementation
will in turn depend on other interfaces, such as 'GTK' (which draws the menus
and buttons, for example).  Thus, the injector must choose implementations of
each dependancy (each of which may require further interfaces, and so on).

<u>The window layout</u>
The top part of the main window displays all these interfaces, and the chosen
version of each one. The top-most one represents the program you tried to run, and
each direct child is a dependancy of the version chosen.

when you select an interface from the top section, a list of available versions
is displayed below. By clicking in the 'Use' column, you can control which version
is chosen. The best 'Preferred' version is used if possible, otherwise the best
unmarked version is chosen. 'Blacklisted' versions are never used. So, if you find
that some version is buggy, just blacklist it here.

Next to the list of versions is a list of implementations of the selected version.
Usually there is only one implementation of each version, but it is possible to have
several. The Use column works in a similar way, to choose an implementation once
the version has been selected.
"""

_help = None

class Help(gtk.Dialog):
	def __init__(self):
		gtk.Dialog.__init__(self)
		self.set_title('Injector help')
		self.set_has_separator(False)

		swin = gtk.ScrolledWindow(None, None)
		swin.set_policy(gtk.POLICY_NEVER, gtk.POLICY_ALWAYS)
		self.vbox.pack_start(swin, True, True)

		text = gtk.Label('')
		text.set_markup(message)
		text.set_alignment(0, 0)
		text.set_padding(8, 8)
		swin.add_with_viewport(text)

		swin.show_all()

		self.add_button(gtk.STOCK_OK, gtk.RESPONSE_OK)
		self.connect('response', lambda box, resp: self.destroy())

		def destroyed(self):
			global _help
			_help = None
		self.connect('destroy', destroyed)

		self.set_position(gtk.WIN_POS_CENTER)
		self.set_default_size(gtk.gdk.screen_width() / 2,
				      gtk.gdk.screen_height() / 2)

def show_help():
	global _help
	if _help:
		_help.destroy()
	_help = Help()
	_help.show()

if __name__ == '__main__':
	show_help()
	gtk.main()
