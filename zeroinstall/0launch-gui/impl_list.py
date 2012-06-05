# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, gobject, os, pango
from zeroinstall import _
from zeroinstall.injector import model, writer
from zeroinstall import support
from zeroinstall.gtkui import gtkutils
import utils

def _build_stability_menu(impl):
	menu = gtk.Menu()

	upstream = impl.upstream_stability or model.testing
	choices = model.stability_levels.values()
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

	item = gtk.MenuItem(_('Unset (%s)') % _(str(upstream).capitalize()).lower())
	item.connect('activate', lambda item: set(None))
	item.show()
	menu.append(item)

	item = gtk.SeparatorMenuItem()
	item.show()
	menu.append(item)

	for value in choices:
		item = gtk.MenuItem(_(str(value)).capitalize())
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

def get_tooltip_text(policy, interface, impl):
	if impl.local_path:
		return _("Local: %s") % impl.local_path
	if impl.id.startswith('package:'):
		return _("Native package: %s") % impl.id.split(':', 1)[1]
	if policy.get_cached(impl):
		return _("Cached: %s") % policy.get_implementation_path(impl)

	src = policy.fetcher.get_best_source(impl)
	if src:
		size = support.pretty_size(src.size)
		return _("Not yet downloaded (%s)") % size
	else:
		return _("No downloads available!")

class ImplementationList:
	tree_view = None
	model = None
	interface = None
	policy = None

	def __init__(self, policy, interface, widgets):
		self.interface = interface
		self.policy = policy

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
					tooltip.set_text(get_tooltip_text(policy, interface, row[ITEM]))
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

			menu = gtk.Menu()

			stability_menu = gtk.MenuItem(_('Rating'))
			stability_menu.set_submenu(_build_stability_menu(impl))
			stability_menu.show()
			menu.append(stability_menu)

			if not impl.id.startswith('package:') and self.policy.get_cached(impl):
				def open():
					os.spawnlp(os.P_WAIT, '0launch',
						'0launch', rox_filer, '-d',
						self.policy.get_implementation_path(impl))
				item = gtk.MenuItem(_('Open cached copy'))
				item.connect('activate', lambda item: open())
				item.show()
				menu.append(item)

			item = gtk.MenuItem(_('Explain this decision'))
			item.connect('activate', lambda item: self.show_explaination(impl))
			item.show()
			menu.append(item)

			menu.popup(None, None, None, bev.button, bev.time)

		self.tree_view.connect('button-press-event', button_press)
	
	def show_explaination(self, impl):
		reason = self.policy.solver.justify_decision(self.policy.requirements, self.interface, impl)
		gtkutils.show_message_box(self.tree_view.get_toplevel(), reason, gtk.MESSAGE_INFO)
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		selected = self.policy.solver.selections.get(self.interface, None)
		for item, unusable in items:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][VERSION] = item.get_version()
			self.model[new][RELEASED] = item.released or "-"
			self.model[new][FETCH] = utils.get_fetch_info(self.policy.config, item)
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
