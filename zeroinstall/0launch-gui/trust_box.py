# -*- coding: utf-8 -*-

import gtk
from zeroinstall.injector.model import SafeException
from zeroinstall.injector import gpg, trust
from zeroinstall.injector.iface_cache import iface_cache

import gui
import dialog, help_box

def fingerprint(sig):
	try:
		return sig.fingerprint
	except:
		# Work around a bug in injector-0.9
		return sig.status[sig.FINGERPRINT]

def pretty_fp(fp):
	s = fp[0:4]
	for x in range(4, len(fp), 4):
		s += ' ' + fp[x:x + 4]
	return s

class TrustBox(dialog.Dialog):
	interface = None
	sigs = None
	iface_xml = None

	def __init__(self, interface, sigs, iface_xml):
		dialog.Dialog.__init__(self)

		def destroy(box):
			assert _queue[0] is self
			del _queue[0]
			if _queue:
				_queue[0].show()
		self.connect('destroy', destroy)

		def left(text):
			label = gtk.Label(text)
			label.set_alignment(0, 0.5)
			label.set_selectable(True)
			return label

		self.interface = interface
		self.sigs = sigs
		self.iface_xml = iface_xml

		self.set_title('Confirm trust')

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		label = left('Checking: ' + interface.uri + '\n\n'
				  'Please confirm that you trust '
				  'these keys to sign software updates:')
		vbox.pack_start(label, False, True, 0)

		notebook = gtk.Notebook()
		vbox.pack_start(notebook, True, True, 0)

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_ADD, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found')

		trust = {}	# Sig -> CheckButton
		def ok_sensitive():
			trust_any = False
			for toggle in trust.values():
				if toggle.get_active():
					trust_any = True
					break
			self.set_response_sensitive(gtk.RESPONSE_OK, trust_any)
		for sig in sigs:
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
			page.pack_start(left('Fingerprint: ' + pretty_fp(fingerprint(sig))), False, True, 0)
			if name is not None:
				page.pack_start(left('Claimed identity: ' + name), False, True, 0)

			frame = gtk.Frame('Unreliable hints database says')
			frame.set_border_width(4)
			hint = left(hints.get(fingerprint(sig), 'Warning: Nothing known about this key!'))
			hint.set_line_wrap(True)
			hint.set_padding(4, 4)
			frame.add(hint)
			page.pack_start(frame, True, True, 0)

			trust[sig] = gtk.CheckButton('_Trust this key')
			page.pack_start(trust[sig], False, True, 0)
			trust[sig].connect('toggled', lambda t: ok_sensitive())

			notebook.append_page(page, gtk.Label(name or 'Signature'))

		ok_sensitive()
		self.vbox.show_all()

		def response(box, resp):
			if resp == gtk.RESPONSE_HELP:
				trust_help.display()
				return
			if resp == gtk.RESPONSE_OK:
				self.trust_keys([sig for sig in trust if trust[sig].get_active()])
			self.destroy()
		self.connect('response', response)
	
	def trust_keys(self, sigs):
		try:
			for sig in sigs:
				trust.trust_db.trust_key(fingerprint(sig))

			if not iface_cache.update_interface_if_trusted(self.interface, self.sigs,
								      self.iface_xml):
				raise Exception('Bug: still not trusted!!')
		except Exception, ex:
			dialog.alert(None, ex)

_queue = []
def confirm_trust(interface, sigs, iface_xml):
	_queue.append(TrustBox(interface, sigs, iface_xml))
	if len(_queue) == 1:
		_queue[0].show()

trust_help = help_box.HelpBox("Trust Help",
('Overview', """
When you run a program, it typically has access to all your files and can generally do \
anything that you're allowed to do (delete files, send emails, etc). So it's important \
to make sure that you don't run anything malicious."""),

('Digital signatures', """
Each software author creates a 'key-pair'; a 'public key' and a 'private key'. Without going \
into the maths, only something encrypted with the private key will decrypt with the public key.

So, when a programmer releases some software, they encrypt it with their private key (which no-one \
else has). When you download it, the injector checks that it decrypts using their public key, thus \
proving that it came from them and hasn't been tampered with."""),

('Trust', """
After the injector has checked that the software hasn't been modified since it was signed with \
the private key, you still have the following problems:

1. Does the public key you have really belong to the author?
2. Even if the software really did come from that person, do you trust them?"""),

('Key fingerprints', """
To confirm (1), you should compare the public key you have with the genuine one. To make this \
easier, the injector displays a 'fingerprint' for the key. Look in mailing list postings or some \
other source to check that the fingerprint is right (a different key will have a different \
fingerprint).

You're trying to protect against the situation where an attacker breaks into a web site \
and puts up malicious software, signed with the attacker's private key, and puts up the \
attacker's public key too. If you've downloaded this software before, you \
should be suspicious that you're being asked to confirm another key!"""),

('Reputation', """
In general, most problems seem to come from malicous and otherwise-unknown people \
replacing software with modified versions, or creating new programs intended only to \
cause damage. So, check your programs are signed by a key with a good reputation!"""))

hints = {
	'1DC295D11A3F910DA49D3839AA1A7812B40B0B6E' :
		'Ken Hayber has been writing ROX applications since 2003. This key '
		'was announced on the rox-users list on 5 Jun 2005.',

	'4338D5420E0BAEB6B2E73530B66A4F24AB8B4B65' :
		'Thomas Formella is experimenting with packaging programs for 0launch. This key '
		'was announced on 11 Sep 2005 on the zero-install mailing list.',

	'92429807C9853C0744A68B9AAE07828059A53CC1' :
		'Thomas Leonard created Zero Install and ROX. This key is used to sign updates to the '
		'injector; you should accept it.',

	'0597A2AFB6B372ACB97AC6E433B938C2E9D8826D' : 
		'Stephen Watson is a project admin for the ROX desktop, and has been involved with the '
		'project since 2000. This key has been used for signing software since the 23 Jul 2005 '
		'announcement on the zero-install mailing list.',
	
	'F0A0CA2A8D8FCC123F5EC04CD8D59DC384AE988E' :
		'Piero Ottuzzi is experimenting with packaging programs for 0launch. This key has been '
		'known since a 16 Mar 2005 post to the zero-install mailing list. It was first used to '
		'sign software in an announcement posted on 9 Aug 2005.',
	
	'FC71DC3364367CE82F91472DDF32928893D894E9' :
		'Niklas Höglund is experimenting with using Zero Install on the Nokia 770. This key has '
		'been known since the announcement of 4 Apr 2006 on the zero-install mailing list.',
	
	'B93AAE76C40A3222425A04FA0BDA706F2C21E592' :
		'Ilja Honkonen is experimenting with packaging software for Zero Install. This key '
		'was announced on 2006-04-21 on the zero-install mailing list.',
	
	'5D3D90FB4E6FE10C7F76E94DEE6BC26DBFDE8022' :
		'Dennis Tomas leads the rox4debian packaging effort. This key has been known since '
		'an email forwarded to the rox-devel list on 2006-05-28.',
}
