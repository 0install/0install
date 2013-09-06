# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys
import gtk
from dialog import Template
from zeroinstall import _
from zeroinstall.gtkui import help_box
from zeroinstall.injector.model import network_levels
from zeroinstall.injector import trust, gpg
from freshness import freshness_levels, Freshness

SHOW_CACHE = 0

class Preferences(object):
	def __init__(self, config, notify_cb = None):
		if notify_cb is None:
			notify_cb = lambda: None

		def connect_toggle(widget_name, setting_name):
			widget = widgets.get_widget(widget_name)
			widget.set_active(getattr(config, setting_name))
			def toggle(w, config = config, setting_name = setting_name):
				setattr(config, setting_name, w.get_active())
				config.save_globals()
				notify_cb()
			widget.connect('toggled', toggle)

		widgets = Template('preferences_box')

		self.window = widgets.get_widget('preferences_box')
		self.window.connect('destroy', lambda w: self.destroyed())

		# (attribute to avoid: free variable 'network' referenced before assignment in enclosing scope)
		self.network = widgets.get_widget('network_use')
		self.network.set_active(list(network_levels).index(config.network_use))

		def set_network_use(combo):
			config.network_use = network_levels[self.network.get_active()]
			config.save_globals()
			notify_cb()
		self.network.connect('changed', set_network_use)

		# Freshness
		times = [x.time for x in freshness_levels]
		if config.freshness not in times:
			freshness_levels.append(Freshness(config.freshness,
							  '%d seconds' % config.freshness))
			times.append(config.freshness)
		freshness = widgets.get_widget('freshness')
		freshness_model = freshness.get_model()
		for level in freshness_levels:
			i = freshness_model.append()
			freshness_model.set_value(i, 0, str(level))
		freshness.set_active(times.index(config.freshness))
		def set_freshness(combo, freshness = freshness): # (pygtk bug?)
			config.freshness = freshness_levels[freshness.get_active()].time
			config.save_globals()
			notify_cb()
		freshness.connect('changed', set_freshness)

		connect_toggle('help_test', 'help_with_testing')

		# Keys
		keys_view = widgets.get_widget('trusted_keys')
		KeyList(keys_view)
		connect_toggle('auto_approve', 'auto_approve_keys')

		# Responses
		self.window.set_default_response(gtk.RESPONSE_CLOSE)
		self.window.get_default_widget().grab_focus()

		def response(dialog, resp):
			if resp in (gtk.RESPONSE_CLOSE, gtk.RESPONSE_DELETE_EVENT):
				self.window.destroy()
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
		self.window.connect('response', response)

		self.window.set_default_size(-1, gtk.gdk.screen_height() / 3)

	def destroyed(self):
		global preferences_box
		preferences_box = None

class KeyList(object):
	def __init__(self, tv):
		self.trusted_keys = gtk.TreeStore(str, object)
		tv.set_model(self.trusted_keys)
		tc = gtk.TreeViewColumn(_('Trusted keys'), gtk.CellRendererText(), text = 0)
		tv.append_column(tc)
		trust.trust_db.ensure_uptodate()

		def update_keys():
			# Remember which ones are open
			expanded_elements = set()
			def add_row(tv, path, unused = None):
				if len(path) == 1:
					domain = self.trusted_keys[path][0]
					expanded_elements.add(domain)
			tv.map_expanded_rows(add_row, None)

			self.trusted_keys.clear()
			domains = {}

			keys = gpg.load_keys(list(trust.trust_db.keys.keys()))

			for fingerprint in keys:
				for domain in trust.trust_db.keys[fingerprint]:
					if domain not in domains:
						domains[domain] = set()
					domains[domain].add(keys[fingerprint])
			for domain in sorted(domains):
				iter = self.trusted_keys.append(None, [domain, None])
				for key in domains[domain]:
					self.trusted_keys.append(iter, [key.name, key])

			def may_expand(model, path, iter, unused):
				if len(path) == 1:
					if model[iter][0] in expanded_elements:
						tv.expand_row(path, False)
			self.trusted_keys.foreach(may_expand, None)

		trust.trust_db.watchers.append(update_keys)
		tv.connect('destroy', lambda w: trust.trust_db.watchers.remove(update_keys))

		update_keys()

		def remove_key(fingerprint, domain):
			trust.trust_db.untrust_key(fingerprint, domain)
			trust.trust_db.notify()

		def trusted_keys_button_press(tv, bev):
			if bev.type == gtk.gdk.BUTTON_PRESS and bev.button == 3:
				pos = tv.get_path_at_pos(int(bev.x), int(bev.y))
				if not pos:
					return False
				path, col, x, y = pos
				if len(path) != 2:
					return False

				key = self.trusted_keys[path][1]
				if isinstance(path, tuple):
					path = path[:-1]		# PyGTK
				else:
					path.up()			# PyGObject
				domain = self.trusted_keys[path][0]

				global menu	# Needed to stop Python 3 GCing the menu and closing it instantly
				menu = gtk.Menu()

				item = gtk.MenuItem()
				item.set_label(_('Remove key for "%s"') % key.get_short_name())
				item.connect('activate',
					lambda item, fp = key.fingerprint, d = domain: remove_key(fp, d))
				item.show()
				menu.append(item)

				if sys.version_info[0] > 2:
					menu.popup(None, None, None, None, bev.button, bev.time)
				else:
					menu.popup(None, None, None, bev.button, bev.time)
				return True
			return False
		tv.connect('button-press-event', trusted_keys_button_press)

preferences_box = None
def show_preferences(config, notify_cb = None):
	global preferences_box
	if preferences_box:
		preferences_box.window.destroy()
	preferences_box = Preferences(config, notify_cb)
	preferences_box.window.show()
	return preferences_box.window
		
gui_help = help_box.HelpBox(_("Zero Install Preferences Help"),
(_('Overview'), '\n\n' +
_("""There are three ways to control which implementations are chosen. You can adjust the \
network policy and the overall stability policy, which affect all interfaces, or you \
can edit the policy of individual interfaces.""")),

(_('Network use'), '\n' +
_("""The 'Network use' option controls how the injector uses the network. If off-line, \
the network is not used at all. If 'Minimal' is selected then the injector will use \
the network if needed, but only if it has no choice. It will run an out-of-date \
version rather than download a newer one. If 'Full' is selected, the injector won't \
worry about how much it downloads, but will always pick the version it thinks is best.""")),

(_('Freshness'), '\n' +
_("""The feed files, which provide the information about which versions are \
available, are also cached. To update them, click on 'Refresh all now'. You can also \
get the injector to check for new versions automatically from time to time using \
the Freshness setting.""")),

(_('Help test new versions'), '\n' +
_("""The overall stability policy can either be to prefer stable versions, or to help test \
new versions. Choose whichever suits you. Since different programmers have different \
ideas of what 'stable' means, you may wish to override this on a per-interface basis.

To set the policy for an interface individually, select it in the main window and \
click on 'Interface Properties'. See that dialog's help text for more information.""")),

(_('Security'), '\n' +
_("""This section lists all keys which you currently trust. When fetching a new program or \
updates for an existing one, the feed must be signed by one of these keys. If not, \
you will be prompted to confirm that you trust the new key, and it will then be added \
to this list.

If "Automatic approval for new feeds" is on, new keys will be automatically approved if \
you haven't used the program before and the key is known to the key information server. \
When updating feeds, confirmation for new keys is always required.

To remove a key, right-click on it and choose 'Remove' from the menu.""")),
)
