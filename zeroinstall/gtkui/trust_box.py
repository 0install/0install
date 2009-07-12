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

def get_hint(fingerprint):
	hint_icon = gtk.Image()
	hint_text = hints.get(fingerprint, None)
	if hint_text:
		hint_icon.set_from_stock(gtk.STOCK_YES, gtk.ICON_SIZE_BUTTON)
	else:
		hint_icon.set_from_stock(gtk.STOCK_DIALOG_WARNING, gtk.ICON_SIZE_BUTTON)
		hint_text = _('Warning: Nothing known about this key!')
	hint = left(hint_text)
	hint.set_line_wrap(True)
	hint_hbox = gtk.HBox(False, 4)
	hint_hbox.pack_start(hint_icon, False, True, 0)
	hint_hbox.pack_start(hint, True, True, 0)
	hint_icon.set_alignment(0, 0)
	return hint_hbox

class TrustBox(gtk.Dialog):
	interface = None
	sigs = None
	iface_xml = None
	valid_sigs = None
	parent = None
	closed = None

	def __init__(self, interface, sigs, iface_xml, parent):
		gtk.Dialog.__init__(self)
		self.set_has_separator(False)
		self.set_position(gtk.WIN_POS_CENTER)
		self.set_transient_for(parent)

		self.closed = tasks.Blocker(_("confirming keys with user"))

		domain = trust.domain_from_url(interface.uri)
		assert domain

		def destroy(box):
			global _queue
			assert _queue[0] is self
			del _queue[0]

			self.closed.trigger()

			# Remove any queued boxes that are no longer required
			def still_untrusted(box):
				for sig in box.valid_sigs:
					is_trusted = trust.trust_db.is_trusted(sig.fingerprint, domain)
					if is_trusted:
						return False
				return True
			if _queue:
				next = _queue[0]
				if still_untrusted(next):
					next.show()
				else:
					next.trust_keys([], domain)
					next.destroy()	# Will trigger this again...
		self.connect('destroy', destroy)

		self.interface = interface
		self.sigs = sigs
		self.iface_xml = iface_xml

		self.set_title(_('Confirm trust'))

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		self.valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not self.valid_sigs:
			raise SafeException(_('No valid signatures found on "%(uri)s". Signatures:%(signatures)s') %
					{'uri': interface.uri, 'signatures': ''.join(['\n- ' + str(s) for s in sigs])})

		notebook = gtk.Notebook()

		if len(self.valid_sigs) == 1:
			notebook.set_show_tabs(False)

		label = left(_('Checking: %s') % interface.uri)
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

		if len(self.valid_sigs) == 1:
			label = left(_('This key signed the feed:'))
		else:
			label = left(_('These keys signed the feed:'))

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

		for sig in self.valid_sigs:
			if hasattr(sig, 'get_details'):
				name = '<unknown>'
				details = sig.get_details()
				for item in details:
					if item[0] in ('pub', 'uid') and \
					   len(item) > 9:
						name = item[9]
						break
			else:
				name = None
			page = gtk.VBox(False, 4)
			page.set_border_width(8)

			frame(page, _('Fingerprint'), pretty_fp(sig.fingerprint))

			if name is not None:
				frame(page, _('Claimed identity'), name)

			frame(page, _('Unreliable hints database says'), get_hint(sig.fingerprint))

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
	
	def trust_keys(self, sigs, domain):
		assert domain
		try:
			for sig in sigs:
				trust.trust_db.trust_key(sig.fingerprint, domain)

			trust.trust_db.notify()
		except Exception, ex:
			gtkutils.show_message_box(self, str(ex), gtk.MESSAGE_ERROR)
			if not isinstance(ex, SafeException):
				raise

_queue = []
def confirm_trust(interface, sigs, iface_xml, parent):
	"""Display a dialog box asking the user to confirm that one of the
	keys is trusted for this domain. If a trust box is already visible, this
	one is queued until the existing one is closed.
	@param interface: the feed being loaded
	@type interface: L{model.Interface}
	@param sigs: the signatures on the feed
	@type sigs: [L{gpg.Signature}]
	@param iface_xml: the downloaded (untrusted) XML document
	@type iface_xml: str
	"""
	box = TrustBox(interface, sigs, iface_xml, parent)
	_queue.append(box)
	if len(_queue) == 1:
		_queue[0].show()
	return box.closed

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

hints = {
	'1DC295D11A3F910DA49D3839AA1A7812B40B0B6E' :
		_('Ken Hayber has been writing ROX applications since 2003. This key '
		'was announced on the rox-users list on 5 Jun 2005.'),

	'4338D5420E0BAEB6B2E73530B66A4F24AB8B4B65' :
		_('Thomas Formella is experimenting with packaging programs for 0launch. This key '
		'was announced on 11 Sep 2005 on the zero-install mailing list.'),

	'92429807C9853C0744A68B9AAE07828059A53CC1' :
		_('Thomas Leonard created Zero Install and ROX. This key is used to sign updates to the '
		'injector; you should accept it.'),

	'DA9825AECAD089757CDABD8E07133F96CA74D8BA' :
		_('Thomas Leonard created Zero Install and ROX. This key is used to sign updates to the '
		'injector; you should accept it. It was announced on the Zero Install mailing list '
		'on 2009-05-31.'),

	'0597A2AFB6B372ACB97AC6E433B938C2E9D8826D' : 
		_('Stephen Watson is a project admin for the ROX desktop, and has been involved with the '
		'project since 2000. This key has been used for signing software since the 23 Jul 2005 '
		'announcement on the zero-install mailing list.'),
	
	'F0A0CA2A8D8FCC123F5EC04CD8D59DC384AE988E' :
		_('Piero Ottuzzi is experimenting with packaging programs for 0launch. This key has been '
		'known since a 16 Mar 2005 post to the zero-install mailing list. It was first used to '
		'sign software in an announcement posted on 9 Aug 2005.'),
	
	'FC71DC3364367CE82F91472DDF32928893D894E9' :
		_('Niklas Höglund is experimenting with using Zero Install on the Nokia 770. This key has '
		'been known since the announcement of 4 Apr 2006 on the zero-install mailing list.'),
	
	'B93AAE76C40A3222425A04FA0BDA706F2C21E592' : # expired
		_('Ilja Honkonen is experimenting with packaging software for Zero Install. This key '
		'was announced on 2006-04-21 on the zero-install mailing list.'),

	'6AD4A9C482F1D3F537C0354FC8CC44742B11FF89' :
		'Ilja Honkonen is experimenting with packaging software for Zero Install. This key '
		'was announced on 2009-06-18 on the zero-install mailing list.',
 	
	'5D3D90FB4E6FE10C7F76E94DEE6BC26DBFDE8022' :
		_('Dennis Tomas leads the rox4debian packaging effort. This key has been known since '
		'an email forwarded to the rox-devel list on 2006-05-28.'),
	
	'2E2B4E59CAC8D874CD2759D34B1095AF2E992B19' :
		'Lennon Cook creates the FreeBSD-x86 binaries for various ROX applications. '
		'This key was announced in a Jun 17, 2006 post to the rox-devel mailing list.',
	
	'7722DC5085B903FF176CCAA9695BA303C9839ABC' :
		_('Lennon Cook creates the FreeBSD-x86 binaries for various ROX applications. '
		'This key was announced in an Oct 5, 2006 post to the rox-users mailing list.'),
	
	'03DC5771716A5A329CA97EA64AB8A8E7613A266F' :
		_('Lennon Cook creates the FreeBSD-x86 binaries for various ROX applications. '
		'This key was announced in an Oct 7, 2007 post to the rox-users mailing list.'),

	'617794D7C3DFE0FFF572065C0529FDB71FB13910' :
		_('This low-security key is used to sign Zero Install interfaces which have been '
		"automatically generated by a script. Typically, the upstream software didn't "
		"come with a signature, so it's impossible to know if the code is actually OK. "
		"However, there is still some benefit: if the archive is modified after the "
		"script has signed it then any further changes will be detected, so this isn't "
		"completely pointless."),

	'5E665D0ECCCF1215F725BD2FA7421904E3D1B654' :
		_('Daniel Carrera works on the OpenDocument viewer from opendocumentfellowship.org. '
		'This key was confirmed in a zero-install mailing list post on 2007-01-09.'),

	'635469E565B8D340C2C9EA4C32FBC18CE63EF486' :
		_('Eric Wasylishen is experimenting with packaging software with Zero Install. '
		'This key was announced on the zero-install mailing list on 2007-01-16 and then lost.'),

	'E5175248514E9D4E558B5925BC456918F32AC5D1' :
		_('Eric Wasylishen is experimenting with packaging software with Zero Install. '
		'This key was announced on the zero-install mailing list on 2008-12-07'),

	'C82D382AAB381A54529019D6A0F9B035686C6996' :
		_("Justus Winter is generating Zero Install feeds from pkgsrc (which was originally "
		"NetBSD's ports collection). This key was announced on the zero-install mailing list "
		"on 2007-06-01."),

	'D7582A2283A01A6480780AC8E1839306AE83E7E2' :
		_('Tom Adams is experimenting with packaging software with Zero Install. '
		'This key was announced on the zero-install mailing list on 2007-08-14.'),
	
	'3B2A89E694686DC4FEEFD6F6D00CA21EC004251B' :
		_('Tuomo Valkonen is the author of the Ion tiling window manager. This key fingerprint '
		'was taken from http://modeemi.fi/~tuomov/ on 2007-11-17.'),

	'A14924F4DFD1B81DED3436240C9B2C41B8D66FEA' :
		_('Andreas K. Förster is experimenting with creating Zero Install feeds. '
		'This key was announced in a 2008-01-25 post to the zeroinstall mailing list.'),
	
	'520DCCDBE5D38E2B22ADD82672E5E2ACF037FFC4' :
		_('Thierry Goubier creates PPC binaries for the ROX desktop. This key was '
		'announced in a 2008-02-03 posting to the rox-users list.'),

	'517085B7261D3B03A97515319C2C2CD1D41AF5BB' :
		_('Frank Richter is a developer of the Crystal Space 3D SDK. This key was '
		'confirmed in a 2008-09-04 post to the zero-install-devel mailing list.'),
}
