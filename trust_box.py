import gtk

import gui
import dialog
import gpg
import trust

def pretty_fp(fp):
	s = fp[0:4]
	for x in range(4, len(fp), 4):
		s += ' ' + fp[x:x + 4]
	return s

class TrustBox(dialog.Dialog):
	model = None
	tree_view = None
	interfaces = None	# Interface -> (xml, [Keys])

	def __init__(self):
		dialog.Dialog.__init__(self)
		self.set_title('Confirm trust')
		self.interfaces = {}

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
		toggle = gtk.CellRendererToggle()

		for column in [gtk.TreeViewColumn('Key fingerprint', text, text = 0)]:
			self.tree_view.append_column(column)

		self.vbox.show_all()
		
		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_ADD, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def response(box, resp):
			if resp == gtk.RESPONSE_OK:
				self.trust_keys()
			self.hide()
		self.connect('response', response)

		self.connect('delete-event', lambda box, ev: True)
	
	def confirm_trust(self, interface, sigs, iface_xml):
		valid_sigs = [s for s in sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			raise SafeException('No valid signatures found')

		self.interfaces[interface] = (iface_xml, valid_sigs)

		self.rebuild_model()
		self.tree_view.expand_all()
		trust_box.present()
	
	def rebuild_model(self):
		ifaces = self.interfaces.keys()
		ifaces.sort()		# Keep the order stable
		self.model.clear()
		for i in ifaces:
			for sig in self.interfaces[i][1]:
				titer = self.model.append()
				self.model[titer][0] = pretty_fp(sig.fingerprint)
				self.model[titer][1] = sig
	
	def trust_keys(self):
		for row in self.model:
			sig = row[1]
			print "Trusing", sig.fingerprint
			trust.trust_db.trust_key(sig.fingerprint)

		ifaces = self.interfaces
		self.interfaces = {}
		self.rebuild_model()
		for i in ifaces:
			iface_xml, sigs = ifaces[i]
			if not gui.policy.update_interface_if_trusted(i, sigs, iface_xml):
				raise Exception('Bug: still not trusted!!')

# Singleton, to avoid opening too many windows at once
trust_box = TrustBox()
