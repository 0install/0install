# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import gtk
from dialog import Template
from zeroinstall.gtkui import help_box
from zeroinstall.injector.model import network_levels
from zeroinstall.injector import trust, gpg
from freshness import freshness_levels, Freshness

SHOW_CACHE = 0

class Preferences:
	def __init__(self, policy):
		widgets = Template('preferences_box')

		self.window = widgets.get_widget('preferences_box')
		self.window.connect('destroy', lambda w: self.destroyed())

		network = widgets.get_widget('network_use')
		network.set_active(list(network_levels).index(policy.network_use))

		def set_network_use(combo):
			policy.network_use = network_levels[network.get_active()]
			policy.save_config()
			policy.solve_with_downloads()
		network.connect('changed', set_network_use)

		# Freshness
		times = [x.time for x in freshness_levels]
		if policy.freshness not in times:
			freshness_levels.append(Freshness(policy.freshness,
							  '%d seconds' % policy.freshness))
			times.append(policy.freshness)
		eb = gtk.EventBox()	# For the tooltip
		freshness = widgets.get_widget('freshness')
		for level in freshness_levels:
			freshness.append_text(str(level))
		freshness.set_active(times.index(policy.freshness))
		def set_freshness(combo):
			policy.freshness = freshness_levels[freshness.get_active()].time
			policy.save_config()
			policy.recalculate()
		freshness.connect('changed', set_freshness)

		stable_toggle = widgets.get_widget('help_test')
		stable_toggle.set_active(policy.help_with_testing)
		def toggle_stability(toggle):
			policy.help_with_testing = toggle.get_active()
			policy.save_config()
			policy.recalculate()
		stable_toggle.connect('toggled', toggle_stability)

		# Keys
		keys_view = widgets.get_widget('trusted_keys')
		KeyList(keys_view)

		# Responses
		self.window.set_default_response(gtk.RESPONSE_CLOSE)
		self.window.default_widget.grab_focus()

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

class KeyList:
	def __init__(self, tv):
		self.trusted_keys = gtk.TreeStore(str, object)
		tv.set_model(self.trusted_keys)
		tc = gtk.TreeViewColumn(_('Trusted keys'), gtk.CellRendererText(), text = 0)
		tv.append_column(tc)
		trust.trust_db.ensure_uptodate()

		def update_keys():
			# Remember which ones are open
			expanded_elements = set()
			def add_row(tv, path):
				if len(path) == 1:
					domain = self.trusted_keys[path][0]
					expanded_elements.add(domain)
			tv.map_expanded_rows(add_row)

			self.trusted_keys.clear()
			domains = {}

			keys = gpg.load_keys(trust.trust_db.keys.keys())

			for fingerprint in keys:
				for domain in trust.trust_db.keys[fingerprint]:
					if domain not in domains:
						domains[domain] = set()
					domains[domain].add(keys[fingerprint])
			for domain in sorted(domains):
				iter = self.trusted_keys.append(None, [domain, None])
				for key in domains[domain]:
					self.trusted_keys.append(iter, [key.name, key])

			def may_expand(model, path, iter):
				if len(path) == 1:
					if model[iter][0] in expanded_elements:
						tv.expand_row(path, False)
			self.trusted_keys.foreach(may_expand)

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

				domain = self.trusted_keys[path[:-1]][0]
				key = self.trusted_keys[path][1]

				menu = gtk.Menu()

				item = gtk.MenuItem(_('Remove key for "%s"') % key.get_short_name())
				item.connect('activate',
					lambda item, fp = key.fingerprint, d = domain: remove_key(fp, d))
				item.show()
				menu.append(item)

				menu.popup(None, None, None, bev.button, bev.time)
				return True
			return False
		tv.connect('button-press-event', trusted_keys_button_press)

preferences_box = None
def show_preferences(policy):
	global preferences_box
	if preferences_box:
		preferences_box.destroy()
	preferences_box = Preferences(policy)
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
to this list. To remove a key, right-click on it and choose 'Remove' from the menu.""")),
)
