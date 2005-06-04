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
	model = None
	tree_view = None

	interface = None
	sigs = None
	iface_xml = None

	def __init__(self, interface, sigs, iface_xml):
		dialog.Dialog.__init__(self)
		self.connect('destroy', lambda a: _pop_queue())

		self.interface = interface
		self.sigs = sigs
		self.iface_xml = iface_xml

		self.set_title('Confirm trust')

		label = gtk.Label('Please confirm that you trust '
				  'these keys to sign software updates:')
		label.set_padding(8, 8)
		self.vbox.pack_start(label, False, True, 0)

		swin = gtk.ScrolledWindow()
		self.vbox.pack_start(swin, True, True, 0)
		swin.set_policy(gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC)
		swin.set_shadow_type(gtk.SHADOW_IN)
		swin.set_border_width(8)

		self.model = gtk.ListStore(str, object)
		self.tree_view = gtk.TreeView(self.model)
		self.tree_view.get_selection().set_mode(gtk.SELECTION_NONE)
		swin.add(self.tree_view)

		self.tree_view.set_size_request(-1, 100)

		text = gtk.CellRendererText()

		for column in [gtk.TreeViewColumn('Key fingerprint', text, text = 0)]:
			self.tree_view.append_column(column)

		self.vbox.show_all()
		
		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_ADD, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def response(box, resp):
			if resp == gtk.RESPONSE_HELP:
				trust_help.display()
				return
			if resp == gtk.RESPONSE_OK:
				self.trust_keys()
			self.destroy()
		self.connect('response', response)
	
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found')

		for sig in sigs:
			titer = self.model.append()
			self.model[titer][0] = pretty_fp(fingerprint(sig))
			self.model[titer][1] = sig

		self.tree_view.expand_all()
		self.present()
	
	def trust_keys(self):
		for row in self.model:
			sig = row[1]
			trust.trust_db.trust_key(fingerprint(sig))

		if not iface_cache.update_interface_if_trusted(self.interface, self.sigs,
							      self.iface_xml):
			raise Exception('Bug: still not trusted!!')

_queue = []
def _pop_queue():
	if _queue:
		a = _queue.pop()
		a.show()

def confirm_trust(interface, sigs, iface_xml):
	_queue.append(TrustBox(interface, sigs, iface_xml))
	if len(_queue) == 1:
		_pop_queue()

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
