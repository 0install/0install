# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import zeroinstall
from zeroinstall import _
from zeroinstall.cmd import slave
from zeroinstall.support import tasks, unicode
from zeroinstall.injector.model import Interface
from zeroinstall.gtkui import help_box

import gtk
from logging import warning

from zeroinstall.gui.dialog import DialogResponse, Template
from zeroinstall.gui.impl_list import ImplementationList
import time
from zeroinstall.gui import dialog

_dialogs = {}	# Interface -> Properties

class Description(object):
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
				from zeroinstall.gui import browser
				browser.open_in_browser(target)
	
	def strtime(self, secs):
		try:
			from locale import nl_langinfo, D_T_FMT
			return time.strftime(nl_langinfo(D_T_FMT), time.localtime(secs))
		except (ImportError, ValueError):
			return time.ctime(secs)

	def set_details(self, details):
		buffer = self.buffer
		heading_style = self.heading_style

		buffer.delete(buffer.get_start_iter(), buffer.get_end_iter())

		iter = buffer.get_start_iter()

		if isinstance(details, Exception):
			buffer.insert(iter, unicode(details))
			return

		for (style, text) in details:
			if style == 'heading':
				buffer.insert_with_tags(iter, text, heading_style)
			elif style == 'link':
				buffer.insert_with_tags(iter, text, self.link_style)
			else:
				buffer.insert(iter, text)

class Feeds(object):
	URI = 0
	ARCH = 1
	USER = 2

	def __init__(self, config, interface, widgets):
		self.config = config
		self.interface = interface

		self.model = gtk.ListStore(str, str, bool)

		self.description = Description(widgets)

		add_remote_feed_button = widgets.get_widget('add_remote_feed')
		add_remote_feed_button.connect('clicked', lambda b: add_remote_feed(config, widgets.get_widget(), interface))

		add_local_feed_button = widgets.get_widget('add_local_feed')
		add_local_feed_button.connect('clicked', lambda b: add_local_feed(config, interface))

		self.remove_feed_button = widgets.get_widget('remove_feed')
		@tasks.async
		def remove_feed(button):
			try:
				model, iter = self.tv.get_selection().get_selected()
				feed_uri = model[iter][Feeds.URI]
				blocker = slave.remove_feed(interface.uri, feed_uri)
				yield blocker
				tasks.check(blocker)
				from zeroinstall.gui import main
				main.recalculate()
			except Exception as ex:
				import traceback
				traceback.print_exc()
				config.handler.report_error(ex)

		self.remove_feed_button.connect('clicked', remove_feed)

		self.tv = widgets.get_widget('feeds_list')
		self.tv.set_model(self.model)
		text = gtk.CellRendererText()
		self.tv.append_column(gtk.TreeViewColumn(_('Source'), text, text = Feeds.URI))
		self.tv.append_column(gtk.TreeViewColumn(_('Arch'), text, text = Feeds.ARCH))

		sel = self.tv.get_selection()
		sel.set_mode(gtk.SELECTION_BROWSE)
		sel.connect('changed', self.sel_changed)
		sel.select_path((0,))

		self.lines = []
	
	def build_model(self, details):
		feeds = details['feeds']
		return [(feed['url'], feed['arch'], feed['type'] == 'user-registered') for feed in feeds]

	@tasks.async
	def sel_changed(self, sel):
		model, miter = sel.get_selected()
		if not miter: return	# build in progress
		# Only enable removing user_override feeds
		enable_remove = model[miter][Feeds.USER]
		self.remove_feed_button.set_sensitive(enable_remove)
		feed_url = model[miter][Feeds.URI]

		try:
			blocker = slave.get_feed_description(feed_url)
			yield blocker
			tasks.check(blocker)
			self.description.set_details(blocker.result)
		except Exception as ex:
			warning("sel_changed", exc_info = ex)
			self.description.set_details(ex)
	
	def updated(self, details):
		new_lines = self.build_model(details)
		if new_lines != self.lines:
			self.lines = new_lines
			self.model.clear()
			for line in self.lines:
				self.model.append(line)
			self.tv.get_selection().select_path((0,))
		else:
			self.sel_changed(self.tv.get_selection())

stability_to_combo_index = { None: 0, "stable": 1, "testing": 2, "developer": 3 }

class Properties(object):
	interface = None
	use_list = None
	window = None
	driver = None
	ignore_stability_change = True

	def __init__(self, driver, interface, iface_name, compile, show_versions = False):
		self.driver = driver

		widgets = Template('interface_properties')

		self.interface = interface

		window = widgets.get_widget('interface_properties')
		self.window = window
		window.set_title(_('Properties for %s') % iface_name)
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

		self.feeds = Feeds(driver.config, interface, widgets)

		stability = widgets.get_widget('preferred_stability')

		self.stability = stability
		stability.connect('changed', lambda *args: self.ignore_stability_change or self.set_stability_policy())

		self.use_list = ImplementationList(driver, interface, widgets)

		self.feeds.tv.grab_focus()

		window.connect('destroy', lambda s: driver.watchers.remove(self.update))
		driver.watchers.append(self.update)
		self.update()

		if show_versions:
			notebook.next_page()

	@tasks.async
	def set_stability_policy(self):
		try:
			i = self.stability.get_active()
			if i == 0:
				new_stability = None
			else:
				new_stability = ['stable', 'testing', 'developer'][i-1]
			blocker = slave.invoke_master(["set-stability-policy", self.interface.uri, new_stability])
			yield blocker
			tasks.check(blocker)
			from zeroinstall.gui import main
			main.recalculate()
		except Exception as ex:
			warning("set_stability_policy", exc_info = ex)

	def show(self):
		self.window.show()

	def destroy(self):
		self.window.destroy()
	
	@tasks.async
	def update(self):
		try:
			blocker = slave.get_component_details(self.interface.uri)
			yield blocker
			tasks.check(blocker)
			self.details = blocker.result

			i = stability_to_combo_index[self.details['stability-policy']]
			self.ignore_stability_change = True
			self.stability.set_active(i)
			self.ignore_stability_change = False

			self.use_list.update(self.details)
			self.feeds.updated(self.details)
			self.compile_button.set_sensitive(self.details['may-compile'])
		except:
			warning("update failed", exc_info = True)
	
@tasks.async
def add_remote_feed(config, parent, interface):
	try:
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

					fetch = slave.add_remote_feed(interface.uri, url)
					if fetch:
						d.set_sensitive(False)
						yield fetch
						d.set_sensitive(True)
						tasks.check(fetch)

						d.destroy()
						from zeroinstall.gui import main
						main.recalculate()
				except zeroinstall.SafeException as ex:
					error(str(ex))
			else:
				d.destroy()
				return
	except Exception as ex:
		import traceback
		traceback.print_exc()
		config.handler.report_error(ex)

def add_local_feed(config, interface):
	chooser = gtk.FileChooserDialog(_('Select XML feed file'), action=gtk.FILE_CHOOSER_ACTION_OPEN, buttons=(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL, gtk.STOCK_OPEN, gtk.RESPONSE_OK))
	@tasks.async
	def ok(feed, config = config, interface = interface, chooser = chooser):
		try:
			blocker = slave.add_local_feed(interface.uri, feed)
			yield blocker
			tasks.check(blocker)

			chooser.destroy()
			from zeroinstall.gui import main
			main.recalculate()
		except Exception as ex:
			dialog.alert(None, _("Error in feed file '%(feed)s':\n\n%(exception)s") % {'feed': feed, 'exception': str(ex)})

	def check_response(widget, response, ok = ok):
		if response == gtk.RESPONSE_OK:
			ok(widget.get_filename())
		elif response == gtk.RESPONSE_CANCEL:
			widget.destroy()

	chooser.connect('response', check_response)
	chooser.show()

def edit(driver, interface, iface_name, compile, show_versions = False):
	assert isinstance(interface, Interface)
	if interface in _dialogs:
		_dialogs[interface].destroy()
	dialog = Properties(driver, interface, iface_name, compile, show_versions = show_versions)
	_dialogs[interface] = dialog
	dialog.show()

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
if it works with all types of system.

If you want to know why a particular version wasn't chosen, right-click over it \
and choose "Explain this decision" from the popup menu.
""") + '\n'),
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
