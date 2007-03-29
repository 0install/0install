import gtk
from logging import warn
import os, sys
import help_box
from gui import policy
from dialog import Dialog, MixedButton, frame
from zeroinstall.injector.model import network_levels
from zeroinstall.injector import trust, gpg
from freshness import freshness_levels, Freshness
from sets import Set

tips = gtk.Tooltips()

SHOW_CACHE = 0

class Preferences(Dialog):
	def __init__(self):
		Dialog.__init__(self)
		self.set_title('Zero Install Preferences')

		self.connect('destroy', lambda w: self.destroyed())

		content = gtk.VBox(False, 2)
		content.set_border_width(8)
		self.vbox.pack_start(content, True, True, 0)

		vbox = gtk.VBox(False, 0)
		frame(content, 'Policy settings', vbox)

		# Network use
		hbox = gtk.HBox(False, 2)
		vbox.pack_start(hbox, False, True, 0)
		hbox.set_border_width(4)

		eb = gtk.EventBox()	# For the tooltip
		network = gtk.combo_box_new_text()
		eb.add(network)
		for level in network_levels:
			network.append_text(level.capitalize())
		network.set_active(list(network_levels).index(policy.network_use))
		hbox.pack_start(gtk.Label('Network use:'), False, True, 0)
		hbox.pack_start(eb, True, True, 2)
		def set_network_use(combo):
			policy.network_use = network_levels[network.get_active()]
			policy.save_config()
			policy.recalculate()
		network.connect('changed', set_network_use)
		tips.set_tip(eb, _('This controls whether the injector will always try to '
			'run the best version, downloading it if needed, or whether it will prefer '
			'to run an older version that is already on your machine.'))

		hbox.show_all()

		# Freshness
		hbox = gtk.HBox(False, 2)
		vbox.pack_start(hbox, False, True, 0)
		hbox.set_border_width(4)

		times = [x.time for x in freshness_levels]
		if policy.freshness not in times:
			freshness_levels.append(Freshness(policy.freshness,
							  '%d seconds' % policy.freshness))
			times.append(policy.freshness)
		eb = gtk.EventBox()	# For the tooltip
		freshness = gtk.combo_box_new_text()
		eb.add(freshness)
		for level in freshness_levels:
			freshness.append_text(str(level))
		freshness.set_active(times.index(policy.freshness))
		hbox.pack_start(gtk.Label('Freshness:'), False, True, 0)
		hbox.pack_start(eb, True, True, 2)
		def set_freshness(combo):
			policy.freshness = freshness_levels[freshness.get_active()].time
			policy.save_config()
			policy.recalculate()
		freshness.connect('changed', set_freshness)
		tips.set_tip(eb, _('Sets how often the injector will check for new versions.'))

		stable_toggle = gtk.CheckButton('Help test new versions')
		vbox.pack_start(stable_toggle, False, True, 0)
		tips.set_tip(stable_toggle,
			"Try out new versions as soon as they are available, instead of "
			"waiting for them to be marked as 'stable'. "
			"This sets the default policy. Click on 'Interface Properties...' "
			"to set the policy for an individual interface.")
		stable_toggle.set_active(policy.help_with_testing)
		def toggle_stability(toggle):
			policy.help_with_testing = toggle.get_active()
			policy.save_config()
			policy.recalculate()
		stable_toggle.connect('toggled', toggle_stability)

		# Keys
		keys_vbox = gtk.VBox(False, 0)
		label = gtk.Label('')
		label.set_markup('<i>You have said that you trust these keys to sign software updates.</i>')
		label.set_padding(4, 4)
		label.set_alignment(0, 0.5)
		keys_vbox.pack_start(label, False, True, 0)

		trusted_keys = gtk.TreeStore(str)
		tv = gtk.TreeView(trusted_keys)
		tc = gtk.TreeViewColumn('Trusted keys', gtk.CellRendererText(), text = 0)
		tv.append_column(tc)
		swin = gtk.ScrolledWindow(None, None)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		swin.add(tv)
		trust.trust_db.ensure_uptodate()
		domains = {}
		for fingerprint in trust.trust_db.keys:
			key = gpg.load_key(fingerprint)
			for domain in trust.trust_db.keys[fingerprint]:
				if domain not in domains:
					domains[domain] = Set()
				domains[domain].add(key)
		for domain in domains:
			iter = trusted_keys.append(None, [domain])
			for key in domains[domain]:
				trusted_keys.append(iter, [key.name])
		keys_vbox.pack_start(swin, True, True, 0)
		frame(content, 'Security', keys_vbox, expand = True)

		# Responses

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CLOSE)

		self.set_default_response(gtk.RESPONSE_CLOSE)
		self.default_widget.grab_focus()

		def response(dialog, resp):
			import download_box
			if resp in (gtk.RESPONSE_CLOSE, gtk.RESPONSE_DELETE_EVENT):
				self.destroy()
			elif resp == gtk.RESPONSE_HELP:
				gui_help.display()
		self.connect('response', response)

		self.set_default_size(-1, gtk.gdk.screen_height() / 3)
		self.vbox.show_all()

	def destroyed(self):
		global preferences_box
		preferences_box = None

preferences_box = None
def show_preferences():
	global preferences_box
	if preferences_box is not None:
		preferences_box.present()
	else:
		preferences_box = Preferences()
		preferences_box.show()
		
gui_help = help_box.HelpBox("Zero Install Preferences Help",
('Overview', """

There are three ways to control which implementations are chosen. You can adjust the \
network policy and the overall stability policy, which affect all interfaces, or you \
can edit the policy of individual interfaces."""),

('Network use', """
The 'Network use' option controls how the injector uses the network. If off-line, \
the network is not used at all. If 'Minimal' is selected then the injector will use \
the network if needed, but only if it has no choice. It will run an out-of-date \
version rather than download a newer one. If 'Full' is selected, the injector won't \
worry about how much it downloads, but will always pick the version it thinks is best."""),

('Freshness', """
The interface files, which provide the information about which versions are \
available, are also cached. To update them, click on 'Refresh all now'. You can also \
get the injector to check for new versions automatically from time to time using \
the Freshness setting."""),

('Help test new versions', """
The overall stability policy can either be to prefer stable versions, or to help test \
new versions. Choose whichever suits you. Since different programmers have different \
ideas of what 'stable' means, you may wish to override this on a per-interface basis.

To set the policy for an interface individually, select it in the main window and \
click on 'Interface Properties'. See that dialog's help text for more information."""),
)
