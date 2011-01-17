# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import zeroinstall
import os
from zeroinstall.support import tasks
from zeroinstall.injector.model import Interface, Feed, stable, testing, developer, stability_levels
from zeroinstall.injector import writer, namespaces, gpg
from zeroinstall.gtkui import help_box

import gtk
from logging import warn

from dialog import DialogResponse, Template
from impl_list import ImplementationList
import time
import dialog

_dialogs = {}	# Interface -> Properties

def enumerate(items):
	x = 0
	for i in items:
		yield x, i
		x += 1

def format_para(para):
	lines = [l.strip() for l in para.split('\n')]
	return ' '.join(lines)

def have_source_for(policy, interface):
	iface_cache = policy.config.iface_cache
	# Note: we don't want to actually fetch the source interfaces at
	# this point, so we check whether:
	# - We have a feed of type 'src' (not fetched), or
	# - We have a source implementation in a regular feed
	for f in iface_cache.get_feed_imports(interface):
		if f.machine == 'src':
			return True
	# Don't have any src feeds. Do we have a source implementation
	# as part of a regular feed?
	for x in iface_cache.get_implementations(interface):
		if x.machine == 'src':
			return True
	return False

class Description:
	def __init__(self, widgets):
		description = widgets.get_widget('description')
		description.connect('button-press-event', self.button_press)

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
				import browser
				browser.open_in_browser(target)
	
	def strtime(self, secs):
		try:
			from locale import nl_langinfo, D_T_FMT
			return time.strftime(nl_langinfo(D_T_FMT), time.localtime(secs))
		except (ImportError, ValueError):
			return time.ctime(secs)

	def set_details(self, iface_cache, feed):
		buffer = self.buffer
		heading_style = self.heading_style

		buffer.delete(buffer.get_start_iter(), buffer.get_end_iter())

		iter = buffer.get_start_iter()

		if feed is None:
			buffer.insert(iter, 'Not yet downloaded.')
			return

		if isinstance(feed, Exception):
			buffer.insert(iter, unicode(feed))
			return

		buffer.insert_with_tags(iter,
			'%s ' % feed.get_name(), heading_style)
		buffer.insert(iter, '(%s)' % feed.summary)

		buffer.insert(iter, '\n%s\n' % feed.url)

		# (converts to local time)
		if feed.last_modified:
			buffer.insert(iter, '\n' + _('Last upstream change: %s') % self.strtime(feed.last_modified))

		if feed.last_checked:
			buffer.insert(iter, '\n' + _('Last checked: %s') % self.strtime(feed.last_checked))

		last_check_attempt = iface_cache.get_last_check_attempt(feed.url)
		if last_check_attempt:
			if feed.last_checked and feed.last_checked >= last_check_attempt:
				pass	# Don't bother reporting successful attempts
			else:
				buffer.insert(iter, '\n' + _('Last check attempt: %s (failed or in progress)') %
						self.strtime(last_check_attempt))

		buffer.insert_with_tags(iter, '\n\n' + _('Description') + '\n', heading_style)

		paragraphs = [format_para(p) for p in (feed.description or "-").split('\n\n')]

		buffer.insert(iter, '\n\n'.join(paragraphs))
		buffer.insert(iter, '\n')

		need_gap = True
		for x in feed.get_metadata(namespaces.XMLNS_IFACE, 'homepage'):
			if need_gap:
				buffer.insert(iter, '\n')
				need_gap = False
			buffer.insert(iter, _('Homepage: '))
			buffer.insert_with_tags(iter, '%s\n' % x.content, self.link_style)

		buffer.insert_with_tags(iter, '\n' + _('Signatures') + '\n', heading_style)
		sigs = iface_cache.get_cached_signatures(feed.url)
		if sigs:
			for sig in sigs:
				if isinstance(sig, gpg.ValidSig):
					name = _('<unknown>')
					details = sig.get_details()
					for item in details:
						if item[0] == 'uid' and len(item) > 9:
							name = item[9]
							break
					buffer.insert_with_tags(iter, _('Valid signature by "%(name)s"\n- Dated: %(sig_date)s\n- Fingerprint: %(sig_fingerprint)s\n') %
							{'name': name, 'sig_date': time.strftime('%c', time.localtime(sig.get_timestamp())), 'sig_fingerprint': sig.fingerprint})
					if not sig.is_trusted():
						if os.path.isabs(feed.url):
							buffer.insert_with_tags(iter, _('WARNING: This key is not in the trusted list') + '\n')
						else:
							buffer.insert_with_tags(iter, _('WARNING: This key is not in the trusted list (either you removed it, or '
											'you trust one of the other signatures)') + '\n')
				else:
					buffer.insert_with_tags(iter, '%s\n' % sig)
		else:
			buffer.insert_with_tags(iter, _('No signature information (old style feed or out-of-date cache)') + '\n')

class Feeds:
	URI = 0
	ARCH = 1
	USED = 2

	def __init__(self, policy, interface, widgets):
		self.policy = policy
		self.interface = interface

		self.model = gtk.ListStore(str, str, bool)

		self.description = Description(widgets)

		self.lines = self.build_model()
		for line in self.lines:
			self.model.append(line)

		add_remote_feed_button = widgets.get_widget('add_remote_feed')
		add_remote_feed_button.connect('clicked', lambda b: add_remote_feed(policy, widgets.get_widget(), interface))

		add_local_feed_button = widgets.get_widget('add_local_feed')
		add_local_feed_button.connect('clicked', lambda b: add_local_feed(policy, interface))

		self.remove_feed_button = widgets.get_widget('remove_feed')
		def remove_feed(button):
			model, iter = self.tv.get_selection().get_selected()
			feed_uri = model[iter][Feeds.URI]
			for x in interface.extra_feeds:
				if x.uri == feed_uri:
					if x.user_override:
						interface.extra_feeds.remove(x)
						writer.save_interface(interface)
						import main
						main.recalculate()
						return
					else:
						dialog.alert(self.get_toplevel(),
							_("Can't remove '%s' as you didn't add it.") % feed_uri)
						return
			raise Exception(_("Missing feed '%s'!") % feed_uri)
		self.remove_feed_button.connect('clicked', remove_feed)

		self.tv = widgets.get_widget('feeds_list')
		self.tv.set_model(self.model)
		text = gtk.CellRendererText()
		self.tv.append_column(gtk.TreeViewColumn(_('Source'), text, text = Feeds.URI, sensitive = Feeds.USED))
		self.tv.append_column(gtk.TreeViewColumn(_('Arch'), text, text = Feeds.ARCH, sensitive = Feeds.USED))

		sel = self.tv.get_selection()
		sel.set_mode(gtk.SELECTION_BROWSE)
		sel.connect('changed', self.sel_changed)
		sel.select_path((0,))
	
	def build_model(self):
		iface_cache = self.policy.config.iface_cache

		usable_feeds = frozenset(self.policy.usable_feeds(self.interface))
		unusable_feeds = frozenset(iface_cache.get_feed_imports(self.interface)) - usable_feeds

		out = [[self.interface.uri, None, True]]

		for feed in usable_feeds:
			out.append([feed.uri, feed.arch, True])
		for feed in unusable_feeds:
			out.append([feed.uri, feed.arch, False])
		return out

	def sel_changed(self, sel):
		iface_cache = self.policy.config.iface_cache

		model, miter = sel.get_selected()
		if not miter: return	# build in progress
		feed_url = model[miter][Feeds.URI]
		# Only enable removing user_override feeds
		enable_remove = False
		for x in self.interface.extra_feeds:
			if x.uri == feed_url:
				if x.user_override:
					enable_remove = True
		self.remove_feed_button.set_sensitive( enable_remove )
		try:
			self.description.set_details(iface_cache, iface_cache.get_feed(feed_url))
		except zeroinstall.SafeException, ex:
			self.description.set_details(iface_cache, ex)
	
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

class Properties:
	interface = None
	use_list = None
	window = None
	policy = None

	def __init__(self, policy, interface, compile, show_versions = False):
		self.policy = policy

		widgets = Template('interface_properties')

		self.interface = interface

		window = widgets.get_widget('interface_properties')
		self.window = window
		window.set_title(_('Properties for %s') % interface.get_name())
		window.set_default_size(-1, gtk.gdk.screen_height() / 3)

		self.compile_button = widgets.get_widget('compile')
		self.compile_button.connect('clicked', lambda b: compile(interface))
		window.set_default_response(gtk.RESPONSE_CANCEL)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CANCEL:
				window.destroy()
			elif resp == gtk.RESPONSE_HELP:
				properties_help.display()
		window.connect('response', response)

		notebook = widgets.get_widget('interface_notebook')
		assert notebook

		feeds = Feeds(policy, interface, widgets)

		stability = widgets.get_widget('preferred_stability')
		stability.set_active(0)
		if interface.stability_policy:
			i = [stable, testing, developer].index(interface.stability_policy)
			i += 1
			if i == 0:
				warn(_("Unknown stability policy %s"), interface.stability_policy)
		else:
			i = 0
		stability.set_active(i)

		def set_stability_policy(combo, stability = stability):	# (pygtk bug?)
			i = stability.get_active()
			if i == 0:
				new_stability = None
			else:
				name = ['stable', 'testing', 'developer'][i-1]
				new_stability = stability_levels[name]
			interface.set_stability_policy(new_stability)
			writer.save_interface(interface)
			import main
			main.recalculate()
		stability.connect('changed', set_stability_policy)

		self.use_list = ImplementationList(policy, interface, widgets)

		self.update_list()

		feeds.tv.grab_focus()

		def updated():
			self.update_list()
			feeds.updated()
			self.shade_compile()
		window.connect('destroy', lambda s: policy.watchers.remove(updated))
		policy.watchers.append(updated)
		self.shade_compile()

		if show_versions:
			notebook.next_page()

	def show(self):
		self.window.show()

	def destroy(self):
		self.window.destroy()
	
	def shade_compile(self):
		self.compile_button.set_sensitive(have_source_for(self.policy, self.interface))
	
	def update_list(self):
		ranked_items = self.policy.solver.details.get(self.interface, None)
		if ranked_items is None:
			# The Solver didn't get this far, but we should still display them!
			ranked_items = [(impl, _("(solve aborted before here)"))
					for impl in self.interface.implementations.values()]
		# Always sort by version
		ranked_items.sort()
		self.use_list.set_items(ranked_items)

@tasks.async
def add_remote_feed(policy, parent, interface):
	try:
		iface_cache = policy.config.iface_cache

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

		d.show()

		def error(message):
			if message:
				error_label.set_text(message)
				error_label.show()
			else:
				error_label.hide()

		while True:
			got_response = DialogResponse(d)
			yield got_response
			tasks.check(got_response)
			resp = got_response.response

			error(None)
			if resp == gtk.RESPONSE_OK:
				try:
					url = entry.get_text()
					if not url:
						raise zeroinstall.SafeException(_('Enter a URL'))
					fetch = policy.fetcher.download_and_import_feed(url, iface_cache)
					if fetch:
						d.set_sensitive(False)
						yield fetch
						d.set_sensitive(True)
						tasks.check(fetch)

						iface = iface_cache.get_interface(url)

						d.set_sensitive(True)
						if not iface.name:
							error(_('Failed to read interface'))
							return
						if not iface.feed_for:
							error(_("Feed '%(feed)s' is not a feed for '%(feed_for)s'.") % {'feed': iface.get_name(), 'feed_for': interface.get_name()})
						elif interface.uri not in iface.feed_for:
							error(_("This is not a feed for '%(uri)s'.\nOnly for:\n%(feed_for)s") %
								{'uri': interface.uri, 'feed_for': '\n'.join(iface.feed_for)})
						elif iface.uri in [f.uri for f in interface.extra_feeds]:
							error(_("Feed from '%s' has already been added!") % iface.uri)
						else:
							interface.extra_feeds.append(Feed(iface.uri, arch = None, user_override = True))
							writer.save_interface(interface)
							d.destroy()
							import main
							main.recalculate()
				except zeroinstall.SafeException, ex:
					error(str(ex))
			else:
				d.destroy()
				return
	except Exception, ex:
		import traceback
		traceback.print_exc()
		policy.handler.report_error(ex)

def add_local_feed(policy, interface):
	chooser = gtk.FileChooserDialog(_('Select XML feed file'), action=gtk.FILE_CHOOSER_ACTION_OPEN, buttons=(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL, gtk.STOCK_OPEN, gtk.RESPONSE_OK))
	def ok(feed):
		from zeroinstall.injector import reader
		try:
			feed_targets = policy.get_feed_targets(feed)
			if interface not in feed_targets:
				raise Exception(_("Not a valid feed for '%(uri)s'; this is a feed for:\n%(feed_for)s") %
						{'uri': interface.uri,
						'feed_for': '\n'.join([f.uri for f in feed_targets])})
			if feed in [f.uri for f in interface.extra_feeds]:
				dialog.alert(None, _('This feed is already registered.'))
			else:
				interface.extra_feeds.append(Feed(feed, user_override = True, arch = None))

			writer.save_interface(interface)
			chooser.destroy()
			reader.update_from_cache(interface)
			import main
			main.recalculate()
		except Exception, ex:
			dialog.alert(None, _("Error in feed file '%(feed)s':\n\n%(exception)s") % {'feed': feed, 'exception': str(ex)})

	def check_response(widget, response):
		if response == gtk.RESPONSE_OK:
			ok(widget.get_filename())
		elif response == gtk.RESPONSE_CANCEL:
			widget.destroy()

	chooser.connect('response', check_response)
	chooser.show()

def edit(policy, interface, compile, show_versions = False):
	assert isinstance(interface, Interface)
	if interface in _dialogs:
		_dialogs[interface].destroy()
	_dialogs[interface] = Properties(policy, interface, compile, show_versions = show_versions)
	_dialogs[interface].show()

properties_help = help_box.HelpBox(_("Injector Properties Help"),
(_('Interface properties'), '\n' +
_("""This window displays information about an interface. There are two tabs at the top: \
Feeds shows the places where the injector looks for implementations of the interface, while \
Versions shows the list of implementations found (from all feeds) in order of preference.""")),

(_('The Feeds tab'), '\n' +
_("""At the top is a list of feeds. By default, the injector uses the full name of the interface \
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
- Then there is a longer description of the interface.""")),

(_('The Versions tab'), '\n' +
_("""This tab shows a list of all known implementations of the interface, from all the feeds. \
The columns have the following meanings:

Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.

Released gives the date this entry was added to the feed.

Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating by right-clicking here (overridden \
values are shown in upper-case). You can also use the special level 'preferred'.

Fetch indicates how much data needs to be downloaded to get this version if you don't \
have it. If the implementation has already been downloaded to your computer, \
it will say (cached). (local) means that you installed this version manually and \
told Zero Install about it by adding a feed. (package) means that this version \
is provided by your distribution's package manager, not by Zero Install. \
In off-line mode, only cached implementations are considered for use.

Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.""") + '\n'),
(_('Sort order'), '\n' +
_("""The implementations are ordered by version number (highest first), with the \
currently selected one in bold. This is the "best" usable version.

Unusable ones are those for incompatible \
architectures, those marked as 'buggy' or 'insecure', versions explicitly marked as incompatible with \
another interface you are using and, in off-line mode, uncached implementations. Unusable \
implementations are shown crossed out.

For the usable implementations, the order is as follows:

- Preferred implementations come first.

- Then, if network use is set to 'Minimal', cached implementations come before \
non-cached.

- Then, implementations at or above the selected stability level come before all others.

- Then, higher-numbered versions come before low-numbered ones.

- Then cached come before non-cached (for 'Full' network use mode).""") + '\n'),

(_('Compiling'), '\n' +
_("""If there is no binary available for your system then you may be able to compile one from \
source by clicking on the Compile button. If no source is available, the Compile button will \
be shown shaded.""") + '\n'))
