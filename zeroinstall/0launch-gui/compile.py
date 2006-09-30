import os, popen2
from xml.dom import minidom, Node
import gtk, gobject
import dialog

from zeroinstall.injector import model, writer
from gui import policy
	
def _iface_name(uri):
	# Uses same logic as 0compile
	iface_name = os.path.basename(uri)
	if iface_name.endswith('.xml'):
		iface_name = iface_name[:-4]
	iface_name = iface_name.replace(' ', '-')
	return iface_name

ENV_FILE = '0compile-env.xml'
XMLNS_0COMPILE = 'http://zero-install.sourceforge.net/2006/namespaces/0compile'

def children(parent, uri, name):
	"""Yield all direct children with the given name."""
	for x in parent.childNodes:
		if x.nodeType == Node.ELEMENT_NODE and x.namespaceURI == uri and x.localName == name:
			yield x

def _get_root_version(build_dir):
	doc = minidom.parse(os.path.join(build_dir, ENV_FILE))
	root = doc.documentElement
	root_iface = root.getAttributeNS(None, 'interface')
	impl_elem = None
	for elem in children(root, XMLNS_0COMPILE, 'interface'):
		if elem.getAttributeNS(None, 'uri') == root_iface:
			assert impl_elem is None
			impl_elems = list(children(elem, XMLNS_0COMPILE, 'implementation'))
			assert len(impl_elems) == 1
			return impl_elems[0].getAttributeNS(None, 'version')
	raise Exception("Missing interface in %s!" % ENV_FILE)

class CompileBox(dialog.Dialog):
	child = None

	def __init__(self, interface, build_dir):
		dialog.Dialog.__init__(self)
		self.set_title(_('Compile ' + interface.get_name()))
		self.set_default_size(gtk.gdk.screen_width() / 2, gtk.gdk.screen_height() / 2)

		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_OK)

		def resp(box, resp):
			box.destroy()
		self.connect('response', resp)

		self.buffer = gtk.TextBuffer()
		tv = gtk.TextView(self.buffer)
		tv.set_wrap_mode(gtk.WRAP_WORD)
		swin = gtk.ScrolledWindow()
		swin.set_policy(gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC)
		swin.add(tv)
		swin.set_shadow_type(gtk.SHADOW_IN)
		tv.set_editable(False)
		tv.set_cursor_visible(False)
		self.vbox.pack_start(swin, True, True, 0)

		self.vbox.show_all()

		def add_feed():
			iface_name = _iface_name(interface.uri)
			version = _get_root_version(build_dir)
			distdir_name = '%s-%s' % (iface_name.lower(), version)
			assert '/' not in distdir_name
			metadir = os.path.realpath(os.path.join(build_dir, distdir_name, '0install'))

			feed = os.path.join(metadir, iface_name + '.xml')

			self.buffer.insert_at_cursor("Registering feed '%s'" % feed)
			interface.feeds.append(model.Feed(feed, arch = None, user_override = True))
			writer.save_interface(interface)
			policy.recalculate()

		def build():
			self.next_step = add_feed
			self.run("cd '%s' && 0launch http://0install.net/2006/interfaces/0compile.xml build" % build_dir)
		self.next_step = build
		self.run(("0launch", "http://0install.net/2006/interfaces/0compile.xml", 'setup', interface.uri, build_dir))
	
	def run(self, command):
		assert self.child is None
		if isinstance(command, basestring):
			self.buffer.insert_at_cursor("Running: " + command + "\n")
		else:
			self.buffer.insert_at_cursor("Running: " + ' '.join(command) + "\n")
		self.child = popen2.Popen4(command)
		self.child.tochild.close()
		gobject.io_add_watch(self.child.fromchild, gobject.IO_IN | gobject.IO_HUP, self.got_data)
	
	def got_data(self, src, cond):
		data = os.read(src.fileno(), 100)
		if data:
			self.buffer.insert_at_cursor(data)
			return True
		else:
			status = self.child.wait()
			self.child = None

			if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
				self.buffer.insert_at_cursor("Command complete.\n")
				if self.next_step:
					self.next_step()
			else:
				self.buffer.insert_at_cursor("Command failed.\n")
			return False
