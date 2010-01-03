"""
A dialog box for confirming GPG keys.
"""

# Copyright (C) 2009, Thomas Leonard
# -*- coding: utf-8 -*-
# See the README file for details, or visit http://0install.net.
from zeroinstall import _

import gtk
from zeroinstall.injector.model import SafeException
from zeroinstall.injector import gpg, trust
from zeroinstall.support import tasks
from zeroinstall.gtkui import help_box, gtkutils

def frame(page, title, content, expand = False):
	frame = gtk.Frame()
	label = gtk.Label()
	label.set_markup('<b>%s</b>' % title)
	frame.set_label_widget(label)
	frame.set_shadow_type(gtk.SHADOW_NONE)
	if type(content) in (str, unicode):
		content = gtk.Label(content)
		content.set_alignment(0, 0.5)
		content.set_selectable(True)
	frame.add(content)
	if hasattr(content, 'set_padding'):
		content.set_padding(8, 4)
	else:
		content.set_border_width(8)
	page.pack_start(frame, expand, True, 0)

def pretty_fp(fp):
	s = fp[0:4]
	for x in range(4, len(fp), 4):
		s += ' ' + fp[x:x + 4]
	return s

def left(text):
	label = gtk.Label(text)
	label.set_alignment(0, 0.5)
	label.set_selectable(True)
	return label

def make_hints_area(closed, key_info_fetcher):
	def text(parent):
		text = ""
		for node in parent.childNodes:
			if node.nodeType == node.TEXT_NODE:
				text = text + node.data
		return text

	hints = gtk.VBox(False, 4)

	shown = set()
	def add_hints():
		infos = set(key_info_fetcher.info) - shown
		for info in infos:
			hints.add(make_hint(info.getAttribute("vote"), text(info)))
			shown.add(info)

		if not(key_info_fetcher.blocker or shown):
			hints.add(make_hint("bad", _('Warning: Nothing known about this key!')))

	if key_info_fetcher.blocker:
		status = left(key_info_fetcher.status)
		hints.add(status)

		@tasks.async
		def update_when_ready():
			while key_info_fetcher.blocker:
				yield key_info_fetcher.blocker, closed
				if closed.happened:
					# The dialog box was closed. Stop updating.
					return
				add_hints()
			status.destroy()
		update_when_ready()
	else:
		add_hints()

	hints.show()
	return hints

def make_hint(vote, hint_text):
	hint_icon = gtk.Image()
	if vote == "good":
		hint_icon.set_from_stock(gtk.STOCK_YES, gtk.ICON_SIZE_BUTTON)
	else:
		hint_icon.set_from_stock(gtk.STOCK_DIALOG_WARNING, gtk.ICON_SIZE_BUTTON)
	hint = left(hint_text)
	hint.set_line_wrap(True)
	hint_hbox = gtk.HBox(False, 4)
	hint_hbox.pack_start(hint_icon, False, True, 0)
	hint_hbox.pack_start(hint, True, True, 0)
	hint_icon.set_alignment(0, 0)
	hint_hbox.show_all()
	return hint_hbox

class TrustBox(gtk.Dialog):
	"""Display a dialog box asking the user to confirm that one of the
	keys is trusted for this domain.
	"""
	parent = None
	closed = None

	def __init__(self, pending, valid_sigs, parent):
		"""@since: 0.42"""
		assert valid_sigs

		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)
		self.set_transient_for(parent)

		self.closed = tasks.Blocker(_("confirming keys with user"))

		domain = trust.domain_from_url(pending.url)
		assert domain

		def destroy(box):
			self.closed.trigger()

		self.connect('destroy', destroy)

		self.set_title(_('Confirm trust'))

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		notebook = gtk.Notebook()

		if len(valid_sigs) == 1:
			notebook.set_show_tabs(False)

		label = left(_('Checking: %s') % pending.url)
		label.set_padding(4, 4)
		vbox.pack_start(label, False, True, 0)

		currently_trusted_keys = trust.trust_db.get_keys_for_domain(domain)
		if currently_trusted_keys:
			keys = [gpg.load_key(fingerprint) for fingerprint in currently_trusted_keys]
			descriptions = [_("%(key_name)s\n(fingerprint: %(key_fingerprint)s)") % {'key_name': key.name, 'key_fingerprint': pretty_fp(key.fingerprint)}
					for key in keys]
		else:
			descriptions = [_('None')]
		frame(vbox, _('Keys already approved for "%s"') % domain, '\n'.join(descriptions))

		label = left(ngettext('This key signed the feed:', 'These keys signed the feed:', len(valid_sigs)))

		label.set_padding(4, 4)
		vbox.pack_start(label, False, True, 0)

		vbox.pack_start(notebook, True, True, 0)

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_ADD, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		trust_checkbox = {}	# Sig -> CheckButton
		def ok_sensitive():
			trust_any = False
			for toggle in trust_checkbox.values():
				if toggle.get_active():
					trust_any = True
					break
			self.set_response_sensitive(gtk.RESPONSE_OK, trust_any)

		for sig in valid_sigs:
			if hasattr(sig, 'get_details'):
				name = '<unknown>'
				details = sig.get_details()
				for item in details:
					if item[0] == 'uid' and len(item) > 9:
						name = item[9]
						break
			else:
				name = None
			page = gtk.VBox(False, 4)
			page.set_border_width(8)

			frame(page, _('Fingerprint'), pretty_fp(sig.fingerprint))

			if name is not None:
				frame(page, _('Claimed identity'), name)

			frame(page, _('Unreliable hints database says'), make_hints_area(self.closed, valid_sigs[sig]))

			already_trusted = trust.trust_db.get_trust_domains(sig.fingerprint)
			if already_trusted:
				frame(page, _('You already trust this key for these domains'),
					'\n'.join(already_trusted))

			trust_checkbox[sig] = gtk.CheckButton(_('_Trust this key'))
			page.pack_start(trust_checkbox[sig], False, True, 0)
			trust_checkbox[sig].connect('toggled', lambda t: ok_sensitive())

			notebook.append_page(page, gtk.Label(name or 'Signature'))

		ok_sensitive()
		self.vbox.show_all()

		def response(box, resp):
			if resp == gtk.RESPONSE_HELP:
				trust_help.display()
				return
			if resp == gtk.RESPONSE_OK:
				self.trust_keys([sig for sig in trust_checkbox if trust_checkbox[sig].get_active()], domain)
			self.destroy()
		self.connect('response', response)
	
	def trust_keys(self, agreed_sigs, domain):
		assert domain
		try:
			for sig in agreed_sigs:
				trust.trust_db.trust_key(sig.fingerprint, domain)

			trust.trust_db.notify()
		except Exception, ex:
			gtkutils.show_message_box(self, str(ex), gtk.MESSAGE_ERROR)
			if not isinstance(ex, SafeException):
				raise

trust_help = help_box.HelpBox(_("Trust Help"),
(_('Overview'), '\n' +
_("""When you run a program, it typically has access to all your files and can generally do \
anything that you're allowed to do (delete files, send emails, etc). So it's important \
to make sure that you don't run anything malicious.""")),

(_('Digital signatures'), '\n' +
_("""Each software author creates a 'key-pair'; a 'public key' and a 'private key'. Without going \
into the maths, only something encrypted with the private key will decrypt with the public key.

So, when a programmer releases some software, they encrypt it with their private key (which no-one \
else has). When you download it, the injector checks that it decrypts using their public key, thus \
proving that it came from them and hasn't been tampered with.""")),

(_('Trust'), '\n' +
_("""After the injector has checked that the software hasn't been modified since it was signed with \
the private key, you still have the following problems:

1. Does the public key you have really belong to the author?
2. Even if the software really did come from that person, do you trust them?""")),

(_('Key fingerprints'), '\n' +
_("""To confirm (1), you should compare the public key you have with the genuine one. To make this \
easier, the injector displays a 'fingerprint' for the key. Look in mailing list postings or some \
other source to check that the fingerprint is right (a different key will have a different \
fingerprint).

You're trying to protect against the situation where an attacker breaks into a web site \
and puts up malicious software, signed with the attacker's private key, and puts up the \
attacker's public key too. If you've downloaded this software before, you \
should be suspicious that you're being asked to confirm another key!""")),

(_('Reputation'), '\n' +
_("""In general, most problems seem to come from malicous and otherwise-unknown people \
replacing software with modified versions, or creating new programs intended only to \
cause damage. So, check your programs are signed by a key with a good reputation!""")))
