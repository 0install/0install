from zeroinstall.injector.model import *
from zeroinstall.injector import writer, namespaces
import gtk, sys, os

import help_box
from dialog import Dialog
from gui import policy
from impl_list import ImplementationList
import time
import dialog

_dialogs = {}	# Interface -> Properties

tips = gtk.Tooltips()

# Response codes
ADD_FEED = 1
COMPILE = 2

def enumerate(items):
	x = 0
	for i in items:
		yield x, i
		x += 1

def format_para(para):
	lines = [l.strip() for l in para.split('\n')]
	return ' '.join(lines)

def open_in_browser(link):
	browser = os.environ.get('BROWSER', 'firefox')
	child = os.fork()
	if child == 0:
		# We are the child
		try:
			os.spawnlp(os.P_NOWAIT, browser, browser, link)
			os._exit(0)
		except Exception, ex:
			print >>sys.stderr, "Error", ex
			os._exit(1)
	os.waitpid(child, 0)

class Description(gtk.ScrolledWindow):
	def __init__(self):
		gtk.ScrolledWindow.__init__(self, None, None)
		self.set_shadow_type(gtk.SHADOW_IN)
		self.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
		description = gtk.TextView()
		description.set_left_margin(4)
		description.set_right_margin(4)
		description.set_wrap_mode(gtk.WRAP_WORD)
		description.set_editable(False)
		description.set_cursor_visible(False)
		description.connect('button-press-event', self.button_press)
		self.add(description)

		self.buffer = description.get_buffer()
		self.heading_style = self.buffer.create_tag(underline = True, scale = 1.2)
		self.link_style = self.buffer.create_tag(underline = True, foreground = 'blue')
		description.set_size_request(-1, 100)
	
	def button_press(self, tv, bev):
		if bev.type == gtk.gdk.BUTTON_PRESS and bev.button == 1:
			x, y = tv.window_to_buffer_coords(tv.get_window_type(bev.window),
							  int(bev.x), int(bev.y))
			itr = tv.get_iter_at_location(x, y)
			if itr and self.link_style in itr.get_tags():
				if not itr.begins_tag(self.link_style):
					itr.backward_to_tag_toggle(self.link_style)
				end = itr.copy()
				end.forward_to_tag_toggle(self.link_style)
				target = itr.get_text(end).strip()
				open_in_browser(target)
	
	def set_details(self, interface):
		buffer = self.buffer
		heading_style = self.heading_style

		buffer.delete(buffer.get_start_iter(), buffer.get_end_iter())

		iter = buffer.get_start_iter()

		buffer.insert_with_tags(iter,
			'%s ' % interface.get_name(), heading_style)
		buffer.insert(iter, '(%s)' % interface.summary)

		buffer.insert(iter, '\n%s\n' % interface.uri)

		# (converts to local time)
		if interface.last_modified:
			buffer.insert(iter, '\nLast upstream change: %s' % time.ctime(interface.last_modified))

		if interface.last_checked:
			buffer.insert(iter, '\nLast checked: %s' % time.ctime(interface.last_checked))

		if hasattr(interface, 'feeds') and interface.feeds:
			for feed in interface.feeds:
				if hasattr(feed, 'uri'):
					feed = feed.uri
				buffer.insert(iter, '\nFeed: %s' % feed)

		buffer.insert_with_tags(iter, '\n\nDescription\n', heading_style)

		paragraphs = [format_para(p) for p in (interface.description or "-").split('\n\n')]

		buffer.insert(iter, '\n\n'.join(paragraphs))

		if hasattr(interface, 'get_metadata'):
			need_gap = True
			for x in interface.get_metadata(namespaces.XMLNS_IFACE, 'homepage'):
				if need_gap:
					buffer.insert(iter, '\n')
					need_gap = False
				buffer.insert(iter, '\nHomepage: ')
				buffer.insert_with_tags(iter, '%s\n' % x.content, self.link_style)


class Properties(Dialog):
	interface = None
	use_list = None

	def __init__(self, interface):
		Dialog.__init__(self)
		self.interface = interface
		self.set_title('Interface ' + interface.get_name())
		self.set_default_size(gtk.gdk.screen_width() / 2,
				      gtk.gdk.screen_height() / 3)

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(4)
		self.vbox.pack_start(vbox, True, True, 0)

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.compile_button = self.add_mixed_button(_('Compile'),
							gtk.STOCK_CONVERT, COMPILE)
		self.compile_button.connect('clicked', self.compile)
		add_feed_button = self.add_mixed_button(_('Add Local Feed...'),
							gtk.STOCK_ADD, ADD_FEED)
		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CANCEL)
		self.set_default_response(gtk.RESPONSE_CANCEL)

		tips.set_tip(add_feed_button,
			_('If you have another implementation of this interface (e.g., a '
			  'CVS checkout), you can add it to the list by registering the XML '
			  'feed file that came with it.'))

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			#elif resp == 1:
			#	policy.begin_iface_download(interface, True)
			elif resp == gtk.RESPONSE_HELP:
				properties_help.display()
			elif resp == ADD_FEED:
				add_feed(interface)
		self.connect('response', response)

		main_hbox = gtk.HBox(False, 5)
		vbox.pack_start(main_hbox, True, True, 0)

		description = Description()
		description.set_details(interface)
		main_hbox.pack_start(description, True, True, 0)

		main_hbox.pack_start(self.build_versions_column(interface), False, True, 0)

		self.update_list()
		vbox.show_all()

		def updated():
			self.update_list()
			description.set_details(interface)
			self.shade_compile()
		self.connect('destroy', lambda s: policy.watchers.remove(updated))
		policy.watchers.append(updated)
		self.shade_compile()
	
	def shade_compile(self):
		# Note: we don't want to actually fetch the source interfaces at
		# this point, so we check whether:
		# - We have a feed of type 'src' (not fetched), or
		# - We have a source implementation in a regular feed
		have_src = False
		for f in self.interface.feeds:
			if f.machine == 'src':
				have_src = True
				break
		if have_src is False:
			# Don't have any src feeds. Do we have a source implementation
			# as part of a regular feed?
			impls = self.interface.implementations.values()
			for f in policy.usable_feeds(self.interface):
				try:
					feed_iface = policy.get_interface(f.uri)
					if feed_iface.implementations:
						impls.extend(feed_iface.implementations.values())
				except NeedDownload:
					pass	# OK, will get called again later
				except Exception, ex:
					warn("Failed to load feed '%s': %s", f.uri, str(ex))
			for x in impls:
				if x.machine == 'src':
					have_src = True
					break
		self.compile_button.set_sensitive(have_src)
	
	def update_list(self):
		impls = policy.get_ranked_implementations(self.interface)
		self.use_list.set_items(impls)

	def build_versions_column(self, interface):
		assert self.use_list is None

		vbox = gtk.VBox(False, 2)

		hbox = gtk.HBox(False, 2)
		vbox.pack_start(hbox, False, True, 2)

		eb = gtk.EventBox()
		stability = gtk.combo_box_new_text()
		eb.add(stability)
		stability.append_text('Use default setting')
		stability.set_active(0)
		for i, x in enumerate((stable, testing, developer)):
			stability.append_text(str(x).capitalize())
			if x is interface.stability_policy:
				stability.set_active(i + 1)
		hbox.pack_start(gtk.Label('Preferred stability:'), False, True, 2)
		hbox.pack_start(eb, True, True, 0)
		def set_stability_policy(combo):
			i = stability.get_active()
			if i == 0:
				new_stability = None
			else:
				name = stability.get_model()[i][0].lower()
				new_stability = stability_levels[name]
			interface.set_stability_policy(new_stability)
			writer.save_interface(interface)
			policy.recalculate()
		stability.connect('changed', set_stability_policy)
		tips.set_tip(eb, _('Implementations at this stability level or higher '
				'will be used in preference to others. You can use this '
				'to override the global "Help test new versions" setting '
				'just for this interface.'))

		self.use_list = ImplementationList(interface)
		self.use_list.set_policy(gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC)
		vbox.pack_start(self.use_list, True, True, 2)

		return vbox
	
	def compile(self, button):
		sel = gtk.FileSelection(_('Create build directory'))
		sel.set_has_separator(False)
		name = os.path.basename(self.interface.uri)
		if name.endswith('.xml'): name = name[:-4]
		sel.set_filename(name)
		def ok(b):
			d = sel.get_filename()
			if os.path.exists(d):
				d = gtk.MessageDialog(sel,
                                             gtk.DIALOG_MODAL,
                                             gtk.MESSAGE_ERROR,
                                             gtk.BUTTONS_OK,
                                             _("'%s' already exists") % d)
				d.run()
				d.destroy()
			else:
				sel.destroy()
				import compile
				box = compile.CompileBox(self.interface, d)
				box.show()
		sel.ok_button.connect('clicked', ok)
		sel.cancel_button.connect('clicked', lambda b: sel.destroy())
		sel.show()

def add_feed(interface):
	sel = gtk.FileSelection(_('Select XML feed file'))
	sel.set_has_separator(False)
	def ok(b):
		from xml.dom import minidom
		from zeroinstall.injector import reader
		feed = sel.get_filename()
		try:
			if hasattr(policy, 'get_feed_targets'):
				feed_targets = policy.get_feed_targets(feed)
				if interface not in feed_targets:
					raise Exception("Not a valid feed for '%s'; this is a feed for:\n%s" %
							(interface.uri,
							'\n'.join([f.uri for f in feed_targets])))
				if interface.get_feed(feed):
					dialog.alert(None, 'This feed is already registered.')
				else:
					interface.feeds.append(Feed(feed, user_override = True, arch = None))
			else:
				doc = minidom.parse(feed)
				uri = doc.documentElement.getAttribute('uri')
				if not uri:
					raise Exception("Missing uri attribute in interface file '%s'" % feed)
				if uri != interface.uri:
					raise Exception("Feed is for interface '%s', not '%s'" %
							(uri, interface.uri))
				if feed in interface.feeds:
					raise Exception("Feed is already registered")
				interface.feeds.append(feed)
			writer.save_interface(interface)
			sel.destroy()
			reader.update_from_cache(interface)
			policy.recalculate()
		except Exception, ex:
			dialog.alert(None, "Error in feed file '%s':\n\n%s" % (feed, str(ex)))
		
	sel.ok_button.connect('clicked', ok)
	sel.cancel_button.connect('clicked', lambda b: sel.destroy())
	sel.show()
	
def edit(interface):
	assert isinstance(interface, Interface)
	if interface in _dialogs:
		_dialogs[interface].destroy()
	_dialogs[interface] = Properties(interface)
	_dialogs[interface].show()

properties_help = help_box.HelpBox("Injector Properties Help",
('Interface properties', """
This window displays information about an interface. On the left is some information \
about the interface: 

- At the top is its short name.
- Below that is the full name; this is also location which is used to update \
the information.
- 'Last upstream change' shows the version of the cached copy of the interface file.
- 'Last checked' is the last time a fresh copy of the upstream interface file was \
downloaded.
- 'Local feed' is shown if you have other sources of versions of this program (for \
example, a CVS checkout).
- Then there is a longer description of the interface."""),

('Implementations', """
The right side of the window is a list of all known implementations of the interface. \
The columns have the following meanings:

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating (overridden values are shown in upper-case). \
You can also use the special level 'preferred'.

C(ached) indicates whether the implementation is already stored on your computer. \
In off-line mode, only cached implementations are considered for use.

Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.
"""),
('Sort order', """
The implementations are listed in the injector's currently preferred order (the one \
at the top will actually be used). Usable implementations all come before unusable \
ones.

Unusable ones are those for incompatible \
architectures, those marked as 'buggy', versions explicitly marked as incompatible with \
another interface you are using and, in off-line mode, uncached implementations. Unusable \
implementations are shown crossed out.

For the usable implementations, the order is as follows:

- Preferred implementations come first.

- Then, if network use is set to 'Minimal', cached implementations come before \
non-cached.

- Then, implementations at or above the selected stability level come before all others.

- Then, higher-numbered versions come before low-numbered ones.

- Then cached come before non-cached (for 'Full' network use mode).
"""),

('Compiling', """
If there is no binary available for your system then you may be able to compile one from \
source by clicking on the Compile button. If no source is available, the Compile button will \
be shown shaded.
"""))
