# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, os, pango, sys
from zeroinstall import _, logger
from zeroinstall.cmd import slave
from zeroinstall.support import tasks
from zeroinstall.injector import model
from zeroinstall.gtkui import gtkutils
from zeroinstall.gui.gui import gobject

def _build_stability_menu(config, impl_details):
	menu = gtk.Menu()

	choices = list(model.stability_levels.values())
	choices.sort()
	choices.reverse()

	@tasks.async
	def set(new):
		try:
			blocker = slave.invoke_master(["set-impl-stability", impl_details['from-feed'], impl_details['id'], new])
			yield blocker
			tasks.check(blocker)
			from zeroinstall.gui import main
			main.recalculate()
		except Exception:
			logger.warning("set", exc_info = True)
			raise

	item = gtk.MenuItem()
	item.set_label(_('Unset'))
	item.connect('activate', lambda item: set(None))
	item.show()
	menu.append(item)

	item = gtk.SeparatorMenuItem()
	item.show()
	menu.append(item)

	for value in choices:
		item = gtk.MenuItem()
		item.set_label(_(str(value)).capitalize())
		item.connect('activate', lambda item, v = value: set(str(v)))
		item.show()
		menu.append(item)

	return menu

rox_filer = 'http://rox.sourceforge.net/2005/interfaces/ROX-Filer'

# Columns
ITEM = 0
ARCH = 1
STABILITY = 2
VERSION = 3
FETCH = 4
UNUSABLE = 5
RELEASED = 6
NOTES = 7
WEIGHT = 8	# Selected item is bold
LANGS = 9

class ImplementationList(object):
	tree_view = None
	model = None
	interface = None
	driver = None

	def __init__(self, driver, interface, widgets):
		self.interface = interface
		self.driver = driver

		self.model = gtk.ListStore(object, str, str, str,	# Item, arch, stability, version,
			   str, gobject.TYPE_BOOLEAN, str, str,		# fetch, unusable, released, notes,
			   int, str)					# weight, langs

		self.tree_view = widgets.get_widget('versions_list')
		self.tree_view.set_model(self.model)

		text = gtk.CellRendererText()
		text_strike = gtk.CellRendererText()

		stability = gtk.TreeViewColumn(_('Stability'), text, text = STABILITY)

		for column in (gtk.TreeViewColumn(_('Version'), text_strike, text = VERSION, strikethrough = UNUSABLE, weight = WEIGHT),
			       gtk.TreeViewColumn(_('Released'), text, text = RELEASED, weight = WEIGHT),
			       stability,
			       gtk.TreeViewColumn(_('Fetch'), text, text = FETCH, weight = WEIGHT),
			       gtk.TreeViewColumn(_('Arch'), text_strike, text = ARCH, strikethrough = UNUSABLE, weight = WEIGHT),
			       gtk.TreeViewColumn(_('Lang'), text_strike, text = LANGS, strikethrough = UNUSABLE, weight = WEIGHT),
			       gtk.TreeViewColumn(_('Notes'), text, text = NOTES, weight = WEIGHT)):
			self.tree_view.append_column(column)

		self.tree_view.set_property('has-tooltip', True)
		def tooltip_callback(widget, x, y, keyboard_mode, tooltip):
			x, y = self.tree_view.convert_widget_to_bin_window_coords(x, y)
			pos = self.tree_view.get_path_at_pos(x, y)
			if pos:
				self.tree_view.set_tooltip_cell(tooltip, pos[0], None, None)
				path = pos[0]
				row = self.model[path]
				if row[ITEM]:
					tooltip.set_text(row[ITEM]['tooltip'])
					return True
			return False
		self.tree_view.connect('query-tooltip', tooltip_callback)

		def button_press(tree_view, bev):
			if bev.button not in (1, 3):
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			impl = self.model[path][ITEM]

			global menu		# Fix GC problem with PyGObject
			menu = gtk.Menu()

			stability_menu = gtk.MenuItem()
			stability_menu.set_label(_('Rating'))
			stability_menu.set_submenu(_build_stability_menu(self.driver.config, impl))
			stability_menu.show()
			menu.append(stability_menu)

			impl_dir = impl['impl-dir']
			if impl_dir:
				def open():
					os.spawnlp(os.P_WAIT, '0launch',
						'0launch', rox_filer, '-d',
						impl_dir)
				item = gtk.MenuItem()
				item.set_label(_('Open cached copy'))
				item.connect('activate', lambda item: open())
				item.show()
				menu.append(item)

			item = gtk.MenuItem()
			item.set_label(_('Explain this decision'))
			item.connect('activate', lambda item: self.show_explaination(impl))
			item.show()
			menu.append(item)

			if sys.version_info[0] < 3:
				menu.popup(None, None, None, bev.button, bev.time)
			else:
				menu.popup(None, None, None, None, bev.button, bev.time)

		self.tree_view.connect('button-press-event', button_press)
	
	@tasks.async
	def show_explaination(self, impl):
		try:
			blocker = slave.justify_decision(self.interface.uri, impl['from-feed'], impl['id'])
			yield blocker
			tasks.check(blocker)
			reason = blocker.result

			parent = self.tree_view.get_toplevel()

			if '\n' not in reason:
				gtkutils.show_message_box(parent, reason, gtk.MESSAGE_INFO)
				return

			box = gtk.Dialog(_("{prog} version {version}").format(
						prog = self.interface.uri,
						version = impl['version']),
					parent,
					gtk.DIALOG_DESTROY_WITH_PARENT,
					(gtk.STOCK_OK, gtk.RESPONSE_OK))

			swin = gtk.ScrolledWindow()
			swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_AUTOMATIC)
			text = gtk.Label(reason)
			swin.add_with_viewport(text)
			swin.show_all()
			box.vbox.pack_start(swin)

			box.set_position(gtk.WIN_POS_CENTER)
			def resp(b, r):
				b.destroy()
			box.connect('response', resp)

			box.set_default_size(gtk.gdk.screen_width() * 3 / 4, gtk.gdk.screen_height() / 3)

			box.show()
		except Exception:
			logger.warning("show_explaination", exc_info = True)
			raise
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def update(self, details):
		self.model.clear()
		selected = details.get('selected-feed', None), details.get('selected-id', None)
		impls = details.get('implementations', None)
		self.tree_view.set_sensitive(impls is not None)
		for item in impls or []:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][VERSION] = item['version']
			self.model[new][RELEASED] = item['released']
			self.model[new][FETCH] = item['fetch']
			user_stability = item['user-stability']
			self.model[new][STABILITY] = user_stability.upper() if user_stability else item['stability']
			self.model[new][ARCH] = item['arch']
			if (item['from-feed'], item['id']) == selected:
				self.model[new][WEIGHT] = pango.WEIGHT_BOLD
			else:
				self.model[new][WEIGHT] = pango.WEIGHT_NORMAL
			self.model[new][UNUSABLE] = not bool(item['usable'])
			self.model[new][LANGS] = item['langs']
			self.model[new][NOTES] = item['notes']
	
	def clear(self):
		self.model.clear()
