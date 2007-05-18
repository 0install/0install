import zeroinstall
from zeroinstall.injector.model import *
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector import writer, namespaces, gpg

import gtk, sys, os
import sets	# Note: for Python 2.3; frozenset is only in Python 2.4
from logging import warn

import help_box
from dialog import Dialog
from gui import policy
from impl_list import ImplementationList
import time
import dialog
import compile

_dialogs = {}	# Interface -> Properties

tips = gtk.Tooltips()

# Response codes
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

def have_source_for(interface):
	# Note: we don't want to actually fetch the source interfaces at
	# this point, so we check whether:
	# - We have a feed of type 'src' (not fetched), or
	# - We have a source implementation in a regular feed
	have_src = False
	for f in interface.feeds:
		if f.machine == 'src':
			return True
	# Don't have any src feeds. Do we have a source implementation
	# as part of a regular feed?
	impls = interface.implementations.values()
	for f in policy.usable_feeds(interface):
		try:
			feed_iface = iface_cache.get_interface(f.uri)
			if feed_iface.implementations:
				impls.extend(feed_iface.implementations.values())
		except zeroinstall.NeedDownload:
			pass	# OK, will get called again later
		except Exception, ex:
			warn("Failed to load feed '%s': %s", f.uri, str(ex))
	for x in impls:
		if x.machine == 'src':
			return True
	return False

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

		if interface.last_check_attempt:
			if interface.last_checked and interface.last_checked >= interface.last_check_attempt:
				pass	# Don't bother reporting successful attempts
			else:
				buffer.insert(iter, '\nLast check attempt: %s (failed or in progress)' %
						time.ctime(interface.last_check_attempt))

		buffer.insert_with_tags(iter, '\n\nDescription\n', heading_style)

		paragraphs = [format_para(p) for p in (interface.description or "-").split('\n\n')]

		buffer.insert(iter, '\n\n'.join(paragraphs))
		buffer.insert(iter, '\n')

		need_gap = True
		for x in interface.get_metadata(namespaces.XMLNS_IFACE, 'homepage'):
			if need_gap:
				buffer.insert(iter, '\n')
				need_gap = False
			buffer.insert(iter, 'Homepage: ')
			buffer.insert_with_tags(iter, '%s\n' % x.content, self.link_style)

		buffer.insert_with_tags(iter, '\nSignatures\n', heading_style)
		sigs = iface_cache.get_cached_signatures(interface.uri)
		if sigs:
			for sig in sigs:
				if isinstance(sig, gpg.ValidSig):
					name = '<unknown>'
					details = sig.get_details()
					for item in details:
						if item[0] in ('pub', 'uid') and len(item) > 9:
							name = item[9]
							break
					buffer.insert_with_tags(iter, 'Valid signature by "%s"\n- Dated: %s\n- Fingerprint: %s\n' %
							(name, time.ctime(sig.get_timestamp()), sig.fingerprint))
					if not sig.is_trusted():
						if interface.uri.startswith('/'):
							buffer.insert_with_tags(iter, 'WARNING: This key is not in the trusted list\n')
						else:
							buffer.insert_with_tags(iter, 'WARNING: This key is not in the trusted list (either you removed it, or '
											'you trust one of the other signatures)\n')
				else:
					buffer.insert_with_tags(iter, '%s\n' % sig)
		else:
			buffer.insert_with_tags(iter, 'No signature information (old style interface or out-of-date cache)\n')

class Feeds(gtk.VPaned):
	URI = 0
	ARCH = 1
	USED = 2

	def __init__(self, interface):
		gtk.VPaned.__init__(self)
		self.set_border_width(4)
		self.interface = interface

		hbox = gtk.HBox(False, 4)
		self.pack1(hbox, False, False)

		self.model = gtk.ListStore(str, str, bool)

		self.lines = self.build_model()
		for line in self.lines:
			self.model.append(line)

		self.swin = gtk.ScrolledWindow()
		self.swin.set_shadow_type(gtk.SHADOW_IN)
		self.swin.set_policy(gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC)
		hbox.pack_start(self.swin, True, True, 0)

		buttons_vbox = gtk.VButtonBox()
		buttons_vbox.set_layout(gtk.BUTTONBOX_START)
		buttons_vbox.set_spacing(4)

		add_remote_feed_button = dialog.MixedButton(_('Add Remote Feed...'), gtk.STOCK_ADD, 0.0)
		add_remote_feed_button.connect('clicked',
			lambda b: add_remote_feed(self.get_toplevel(), interface))
		buttons_vbox.add(add_remote_feed_button)

		add_local_feed_button = dialog.MixedButton(_('Add Local Feed...'), gtk.STOCK_ADD, 0.0)
		add_local_feed_button.connect('clicked', lambda b: add_local_feed(interface))
		tips.set_tip(add_local_feed_button,
			_('If you have another implementation of this interface (e.g. a '
			  'CVS checkout), you can add it to the list by registering the XML '
			  'feed file that came with it.'))
		buttons_vbox.add(add_local_feed_button)

		self.remove_feed_button = dialog.MixedButton(_('Remove Feed'), gtk.STOCK_REMOVE, 0.0)
		def remove_feed(button):
			model, iter = self.tv.get_selection().get_selected()
			feed_uri = model[iter][Feeds.URI]
			for x in interface.feeds:
				if x.uri == feed_uri:
					if x.user_override:
						interface.feeds.remove(x)
						writer.save_interface(interface)
						policy.recalculate()
						return
					else:
						dialog.alert(self.get_toplevel(),
							_("Can't remove '%s' as you didn't add it.") % feed_uri)
						return
			raise Exception("Missing feed '%s'!" % feed_uri)
		self.remove_feed_button.connect('clicked', remove_feed)
		buttons_vbox.add(self.remove_feed_button)

		hbox.pack_start(buttons_vbox, False, True, 0)

		self.tv = gtk.TreeView(self.model)
		text = gtk.CellRendererText()
		self.tv.append_column(gtk.TreeViewColumn('Source', text, text = Feeds.URI, sensitive = Feeds.USED))
		self.tv.append_column(gtk.TreeViewColumn('Arch', text, text = Feeds.ARCH, sensitive = Feeds.USED))
		self.swin.add(self.tv)

		self.description = Description()
		self.add2(self.description)

		sel = self.tv.get_selection()
		sel.set_mode(gtk.SELECTION_BROWSE)
		sel.connect('changed', self.sel_changed)
		sel.select_path((0,))
	
	def build_model(self):
		usable_feeds = sets.ImmutableSet(policy.usable_feeds(self.interface))
		unusable_feeds = sets.ImmutableSet(self.interface.feeds) - usable_feeds

		out = [[self.interface.uri, None, True]]

		if self.interface.feeds:
			for feed in usable_feeds:
				out.append([feed.uri, feed.arch, True])
			for feed in unusable_feeds:
				out.append([feed.uri, feed.arch, False])
		return out

	def sel_changed(self, sel):
		model, miter = sel.get_selected()
		if not miter: return	# build in progress
		iface = model[miter][Feeds.URI]
		# Only enable removing user_override feeds
		enable_remove = False
		for x in self.interface.feeds:
			if x.uri == iface:
				if x.user_override:
					enable_remove = True
		self.remove_feed_button.set_sensitive( enable_remove )
		self.description.set_details(iface_cache.get_interface(iface))
	
	def updated(self):
		new_lines = self.build_model()
		if new_lines != self.lines:
			self.lines = new_lines
			self.model.clear()
			for line in self.lines:
				self.model.append(line)
			self.tv.get_selection().select_path((0,))
		else:
			self.sel_changed(self.tv.get_selection())

class Properties(Dialog):
	interface = None
	use_list = None

	def __init__(self, interface, show_versions = False):
		Dialog.__init__(self)
		self.interface = interface
		self.set_title('Interface ' + interface.get_name())
		self.set_default_size(-1,
				      gtk.gdk.screen_height() / 3)

		self.add_button(gtk.STOCK_HELP, gtk.RESPONSE_HELP)
		self.compile_button = self.add_mixed_button(_('Compile'),
							gtk.STOCK_CONVERT, COMPILE)
		self.compile_button.connect('clicked', lambda b: compile.compile(interface))
		self.add_button(gtk.STOCK_CLOSE, gtk.RESPONSE_CANCEL)
		self.set_default_response(gtk.RESPONSE_CANCEL)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				self.destroy()
			elif resp == gtk.RESPONSE_HELP:
				properties_help.display()
		self.connect('response', response)

		notebook = gtk.Notebook()
		self.vbox.pack_start(notebook, True, True, 0)

		feeds = Feeds(interface)
		notebook.append_page(feeds, gtk.Label(_('Feeds')))
		notebook.append_page(self.build_versions_column(interface), gtk.Label(_('Versions')))

		self.update_list()
		notebook.show_all()

		feeds.tv.grab_focus()

		def updated():
			self.update_list()
			feeds.updated()
			self.shade_compile()
		self.connect('destroy', lambda s: policy.watchers.remove(updated))
		policy.watchers.append(updated)
		self.shade_compile()

		if show_versions:
			notebook.next_page()
	
	def shade_compile(self):
		self.compile_button.set_sensitive(have_source_for(self.interface))
	
	def update_list(self):
		impls = policy.get_ranked_implementations(self.interface)
		self.use_list.set_items(impls)

	def build_versions_column(self, interface):
		assert self.use_list is None

		vbox = gtk.VBox(False, 2)
		vbox.set_border_width(4)

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
		hbox.pack_start(eb, False, True, 0)
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
		vbox.pack_start(self.use_list, True, True, 2)

		return vbox
	
def add_remote_feed(parent, interface):
	d = gtk.MessageDialog(parent, 0, gtk.MESSAGE_QUESTION, gtk.BUTTONS_CANCEL,
		_('Enter the URL of the new source of implementations of this interface:'))
	d.add_button(gtk.STOCK_ADD, gtk.RESPONSE_OK)
	d.set_default_response(gtk.RESPONSE_OK)
	entry = gtk.Entry()

	align = gtk.VBox(False, 0)
	align.set_border_width(4)
	align.add(entry)
	d.vbox.pack_start(align)
	entry.set_activates_default(True)

	entry.set_text('')

	d.vbox.show_all()

	error_label = gtk.Label('')
	error_label.set_padding(4, 4)
	align.pack_start(error_label)

	def error(message):
		if message:
			error_label.set_text(message)
			error_label.show()
		else:
			error_label.hide()

	def download_done(iface):
		d.set_sensitive(True)
		if not iface.name:
			error('Failed to read interface')
			return
		if not iface.feed_for:
			error("Interface '%s' is not a feed." % iface.get_name())
		elif interface.uri not in iface.feed_for:
			error("Interface is not a feed for '%s'.\nOnly for:\n%s" %
				(interface.uri, '\n'.join(iface.feed_for)))
		elif iface.uri in [f.uri for f in interface.feeds]:
			error("Feed from '%s' has already been added!" % iface.uri)
		else:
			interface.feeds.append(Feed(iface.uri, arch = None, user_override = True))
			writer.save_interface(interface)
			d.destroy()
			policy.recalculate()

	def response(d, resp):
		error(None)
		if resp == gtk.RESPONSE_OK:
			try:
				url = entry.get_text()
				if not url:
					raise SafeException(_('Enter a URL'))
				iface = iface_cache.get_interface(url)
				policy.begin_iface_download(iface) # Force a refresh
				d.set_sensitive(False)
				policy.handler.add_dl_callback(url, lambda: download_done(iface))
			except SafeException, ex:
				error(str(ex))
		else:
			d.destroy()
			return
	d.connect('response', response)
	d.show()

def add_local_feed(interface):
	sel = gtk.FileSelection(_('Select XML feed file'))
	sel.set_has_separator(False)
	def ok(b):
		from xml.dom import minidom
		from zeroinstall.injector import reader
		feed = sel.get_filename()
		try:
			feed_targets = policy.get_feed_targets(feed)
			if interface not in feed_targets:
				raise Exception("Not a valid feed for '%s'; this is a feed for:\n%s" %
						(interface.uri,
						'\n'.join([f.uri for f in feed_targets])))
			if interface.get_feed(feed):
				dialog.alert(None, 'This feed is already registered.')
			else:
				interface.feeds.append(Feed(feed, user_override = True, arch = None))

			writer.save_interface(interface)
			sel.destroy()
			reader.update_from_cache(interface)
			policy.recalculate()
		except Exception, ex:
			dialog.alert(None, "Error in feed file '%s':\n\n%s" % (feed, str(ex)))
		
	sel.ok_button.connect('clicked', ok)
	sel.cancel_button.connect('clicked', lambda b: sel.destroy())
	sel.show()
	
def edit(interface, show_versions = False):
	assert isinstance(interface, Interface)
	if interface in _dialogs:
		_dialogs[interface].destroy()
	_dialogs[interface] = Properties(interface, show_versions)
	_dialogs[interface].show()

properties_help = help_box.HelpBox("Injector Properties Help",
('Interface properties', """
This window displays information about an interface. There are two tabs at the top: \
Feeds shows the places where the injector looks for implementations of the interface, while \
Versions shows the list of implementations found (from all feeds) in order of preference."""),

('The Feeds tab', """
At the top is a list of feeds. By default, the injector uses the full name of the interface \
as the default feed location (so if you ask it to run the program "http://foo/bar.xml" then it will \
by default get the list of versions by downloading "http://foo/bar.xml".

You can add and remove feeds using the buttons on the right. The main feed may also add \
some extra feeds itself. If you've checked out a developer version of a program, you can use \
the 'Add Local Feed...' button to let the injector know about it, for example.

Below the list of feeds is a box describing the selected one:

- At the top is its short name.
- Below that is the address (a URL or filename).
- 'Last upstream change' shows the version of the cached copy of the interface file.
- 'Last checked' is the last time a fresh copy of the upstream interface file was \
downloaded.
- Then there is a longer description of the interface."""),

('The Versions tab', """
This tab shows a list of all known implementations of the interface, from all the feeds. \
The columns have the following meanings:

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Released gives the date this entry was added to the feed.

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
