# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk, gobject, os
from zeroinstall.injector import model, writer
from zeroinstall import support
from zeroinstall.gtkui.treetips import TreeTips
import utils

def _build_stability_menu(policy, impl):
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
		policy.recalculate()

	item = gtk.MenuItem(_('Unset (%s)') % upstream)
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

class ImplTips(TreeTips):
	def __init__(self, policy, interface):
		self.policy = policy
		self.interface = interface

	def get_tooltip_text(self):
		impl = self.item
		if impl.id.startswith('/'):
			return _("Local: %s") % impl.id
		if impl.id.startswith('package:'):
			return _("Native package: %s") % impl.id.split(':', 1)[1]
		if self.policy.get_cached(impl):
			return _("Cached: %s") % self.policy.get_implementation_path(impl)

		src = self.policy.fetcher.get_best_source(impl)
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
			   str, gobject.TYPE_BOOLEAN, str, str)		# fetch, unusable, released, notes

		self.tree_view = widgets.get_widget('versions_list')
		self.tree_view.set_model(self.model)

		text = gtk.CellRendererText()
		text_strike = gtk.CellRendererText()

		stability = gtk.TreeViewColumn(_('Stability'), text, text = STABILITY)

		for column in (gtk.TreeViewColumn(_('Version'), text_strike, text = VERSION, strikethrough = UNUSABLE),
			       gtk.TreeViewColumn(_('Released'), text, text = RELEASED),
			       stability,
			       gtk.TreeViewColumn(_('Fetch'), text, text = FETCH),
			       gtk.TreeViewColumn(_('Arch'), text_strike, text = ARCH, strikethrough = UNUSABLE),
			       gtk.TreeViewColumn(_('Notes'), text, text = NOTES)):
			self.tree_view.append_column(column)

		tips = ImplTips(policy, interface)

		def motion(tree_view, ev):
			if ev.window is not tree_view.get_bin_window():
				return False
			pos = tree_view.get_path_at_pos(int(ev.x), int(ev.y))
			if pos:
				path = pos[0]
				row = self.model[path]
				if row[ITEM] is not tips.item:
					tips.prime(tree_view, row[ITEM])
			else:
				tips.hide()

		self.tree_view.connect('motion-notify-event', motion)
		self.tree_view.connect('leave-notify-event', lambda tv, ev: tips.hide())
		self.tree_view.connect('destroy', lambda tv: tips.hide())

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
			stability_menu.set_submenu(_build_stability_menu(self.policy, impl))
			stability_menu.show()
			menu.append(stability_menu)

			if self.policy.get_cached(impl):
				def open():
					os.spawnlp(os.P_WAIT, '0launch',
						'0launch', rox_filer, '-d',
						self.policy.get_implementation_path(impl))
				item = gtk.MenuItem(_('Open cached copy'))
				item.connect('activate', lambda item: open())
				item.show()
				menu.append(item)

			menu.popup(None, None, None, bev.button, bev.time)

		self.tree_view.connect('button-press-event', button_press)
	
	def get_selection(self):
		return self.tree_view.get_selection()
	
	def set_items(self, items):
		self.model.clear()
		for item, unusable in items:
			new = self.model.append()
			self.model[new][ITEM] = item
			self.model[new][VERSION] = item.get_version()
			self.model[new][RELEASED] = item.released or "-"
			self.model[new][FETCH] = utils.get_fetch_info(self.policy, item)
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
			self.model[new][UNUSABLE] = bool(unusable)
			self.model[new][NOTES] = _(unusable)
	
	def clear(self):
		self.model.clear()
