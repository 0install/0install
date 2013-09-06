# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, os, pango, sys
from zeroinstall import _
from zeroinstall.injector import model, writer
from zeroinstall import support
from zeroinstall.gtkui import gtkutils
import utils
from gui import gobject

def _build_stability_menu(impl):
	menu = gtk.Menu()

	upstream = impl.upstream_stability or model.testing
	choices = list(model.stability_levels.values())
	choices.sort()
	choices.reverse()

	def set(new):
		if isinstance(new, model.Stability):
			impl.user_stability = new
		else:
			impl.user_stability = None
		writer.save_feed(impl.feed)
		import main
		main.recalculate()

	item = gtk.MenuItem()
	item.set_label(_('Unset (%s)') % _(str(upstream).capitalize()).lower())
	item.connect('activate', lambda item: set(None))
	item.show()
	menu.append(item)

	item = gtk.SeparatorMenuItem()
	item.show()
	menu.append(item)

	for value in choices:
		item = gtk.MenuItem()
		item.set_label(_(str(value)).capitalize())
		item.connect('activate', lambda item, v = value: set(v))
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

def get_tooltip_text(config, interface, impl):
	if impl.local_path:
		return _("Local: %s") % impl.local_path
	if impl.id.startswith('package:'):
		return _("Native package: %s") % impl.id.split(':', 1)[1]
	if impl.is_available(config.stores):
		return _("Cached: %s") % config.stores.lookup_any(impl.digests)

	src = config.fetcher.get_best_source(impl)
	if src:
		size = support.pretty_size(src.size)
		return _("Not yet downloaded (%s)") % size
	else:
		return _("No downloads available!")

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
					tooltip.set_text(get_tooltip_text(driver.config, interface, row[ITEM]))
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
			stability_menu.set_submenu(_build_stability_menu(impl))
			stability_menu.show()
			menu.append(stability_menu)

			if not impl.id.startswith('package:') and impl.is_available(self.driver.config.stores):
				def open():
					os.spawnlp(os.P_WAIT, '0launch',
						'0launch', rox_filer, '-d',
						impl.local_path or self.driver.config.stores.lookup_any(impl.digests))
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
	
	def show_explaination(self, impl):
		reason = self.driver.solver.justify_decision(self.driver.requirements, self.interface, impl)

		parent = self.tree_view.get_toplevel()

		if '\n' not in reason:
			gtkutils.show_message_box(parent, reason, gtk.MESSAGE_INFO)
			return

		box = gtk.Dialog(_("{prog} version {version}").format(
					prog = self.interface.get_name(),
					version = impl.get_version()),
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
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		selected = self.driver.solver.selections.get(self.interface, None)
		for item, unusable in items:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][VERSION] = item.get_version()
			self.model[new][RELEASED] = item.released or "-"
			self.model[new][FETCH] = utils.get_fetch_info(self.driver.config, item)
			if item.user_stability:
				if item.user_stability == model.insecure:
					self.model[new][STABILITY] = _('INSECURE')
				elif item.user_stability == model.buggy:
					self.model[new][STABILITY] = _('BUGGY')
				elif item.user_stability == model.developer:
					self.model[new][STABILITY] = _('DEVELOPER')
				elif item.user_stability == model.testing:
					self.model[new][STABILITY] = _('TESTING')
				elif item.user_stability == model.stable:
					self.model[new][STABILITY] = _('STABLE')
				elif item.user_stability == model.packaged:
					self.model[new][STABILITY] = _('PACKAGED')
				elif item.user_stability == model.preferred:
					self.model[new][STABILITY] = _('PREFERRED')
			else:
				self.model[new][STABILITY] = _(str(item.upstream_stability) or str(model.testing))
			self.model[new][ARCH] = item.arch or _('any')
			if selected is item:
				self.model[new][WEIGHT] = pango.WEIGHT_BOLD
			else:
				self.model[new][WEIGHT] = pango.WEIGHT_NORMAL
			self.model[new][UNUSABLE] = bool(unusable)
			self.model[new][LANGS] = item.langs or '-'
			self.model[new][NOTES] = unusable and _(unusable) or _('None')
	
	def clear(self):
		self.model.clear()
