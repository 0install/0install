"""Display the contents of the implementation cache."""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

from zeroinstall import _
import os, sys
import gtk

from zeroinstall.injector import namespaces, model
from zeroinstall.zerostore import BadDigest, manifest
from zeroinstall import support
from zeroinstall.support import basedir, tasks
from zeroinstall.gtkui import help_box, gtkutils

__all__ = ['CacheExplorer']

ROX_IFACE = 'http://rox.sourceforge.net/2005/interfaces/ROX-Filer'

# Tree view columns
class Column(object):
	columns = []
	def __init__(self, name, column_type, resizable=False, props={}, hide=False, markup=False):
		self.idx = len(self.columns)
		self.columns.append(self)
		self.name = name
		self.column_type = column_type
		self.props = props
		self.resizable = resizable
		self.hide = hide
		self.markup = markup

	@classmethod
	def column_types(cls):
		return [col.column_type for col in cls.columns]
	
	@classmethod
	def add_all(cls, tree_view):
		[col.add(tree_view) for col in cls.columns]
	
	def get_cell(self):
		cell = gtk.CellRendererText()
		self.set_props(cell, self.props)
		return cell
	
	def set_props(self, obj, props):
		for k,v in props.items():
			obj.set_property(k, v)

	def get_column(self):
		if self.markup:
			kwargs = {'markup': self.idx}
		else:
			kwargs = {'text': self.idx}
		column = gtk.TreeViewColumn(self.name, self.get_cell(), **kwargs)
		if 'xalign' in self.props:
			self.set_props(column, {'alignment': self.props['xalign']})
		return column

	def add(self, tree_view):
		if self.hide:
			return
		column = self.get_column()
		if self.resizable: column.set_resizable(True)
		tree_view.append_column(column)

NAME = Column(_('Name'), str, hide=True)
URI = Column(_('URI'), str, hide=True)
TOOLTIP = Column(_('Description'), str, hide=True)
ITEM_VIEW = Column(_('Item'), str, props={'ypad': 6, 'yalign': 0}, resizable=True, markup=True)
SELF_SIZE = Column(_('Self Size'), int, hide=True)
TOTAL_SIZE = Column(_('Total Size'), int, hide=True)
PRETTY_SIZE = Column(_('Size'), str, props={'xalign':1.0})
ITEM_OBJECT = Column(_('Object'), object, hide=True)

ACTION_REMOVE = object() # just make a unique value

class Section(object):
	may_delete = False
	def __init__(self, name, tooltip):
		self.name = name
		self.tooltip = tooltip

	def append_to(self, model):
		return model.append(None, extract_columns(
			name=self.name,
			tooltip=self.tooltip,
			object=self,
		))

SECTION_INTERFACES = Section(
	_("Feeds"),
	_("Feeds in the cache"))
SECTION_UNOWNED_IMPLEMENTATIONS = Section(
	_("Unowned implementations and temporary files"),
	_("These probably aren't needed any longer. You can delete them."))
SECTION_INVALID_INTERFACES = Section(
	_("Invalid feeds (unreadable)"),
	_("These feeds exist in the cache but cannot be read. You should probably delete them."))

import cgi
def extract_columns(**d):
	vals = list(map(lambda x:None, Column.columns))
	def setcol(column, val):
		vals[column.idx] = val

	name = d.get('name', None)
	desc = d.get('desc', None)
	uri = d.get('uri', None)

	setcol(NAME, name)
	setcol(URI, uri)
	if name and uri:
		setcol(ITEM_VIEW, '<span font-size="larger" weight="bold">%s</span>\n'
		'<span color="#666666">%s</span>' % tuple(map(cgi.escape, (name, uri))))
	else:
		setcol(ITEM_VIEW, cgi.escape(name or desc))

	size = d.get('size', 0)
	setcol(SELF_SIZE, size)
	setcol(TOTAL_SIZE, 0) # must be set to prevent type error
	setcol(TOOLTIP, d.get('tooltip', None))
	setcol(ITEM_OBJECT, d.get('object', None))
	return vals

menu = None
def popup_menu(bev, obj, model, path, cache_explorer):
	global menu	# Fixes Python 3 GC issues
	menu = gtk.Menu()
	for i in obj.menu_items:
		if i is None:
			item = gtk.SeparatorMenuItem()
		else:
			name, cb = i
			item = gtk.MenuItem()
			item.set_label(name)
			def _cb(item, cb=cb):
				action_required = cb(obj, cache_explorer)
				if action_required is ACTION_REMOVE:
					model.remove(model.get_iter(path))
			item.connect('activate', _cb)
		item.show()
		menu.append(item)
	if gtk.pygtk_version >= (2, 90):
		menu.popup(None, None, None, None, bev.button, bev.time)
	else:
		menu.popup(None, None, None, bev.button, bev.time)

def warn(message, parent=None):
	"Present a blocking warning message with OK/Cancel buttons, and return True if OK was pressed"
	dialog = gtk.MessageDialog(parent=parent, buttons=gtk.BUTTONS_OK_CANCEL, type=gtk.MESSAGE_WARNING)
	dialog.set_property('text', message)
	response = []
	def _response(dialog, resp):
		if resp == gtk.RESPONSE_OK:
			response.append(True)
	dialog.connect('response', _response)
	dialog.run()
	dialog.destroy()
	return bool(response)

def size_if_exists(path):
	"Get the size for a file, or 0 if it doesn't exist."
	if path and os.path.isfile(path):
		return os.path.getsize(path)
	return 0

def get_size(path):
	"Get the size for a directory tree. Get the size from the .manifest if possible."
	man = os.path.join(path, '.manifest')
	if os.path.exists(man):
		size = os.path.getsize(man)
		with open(man, 'rt') as stream:
			for line in stream:
				if line[:1] in "XF":
					size += int(line.split(' ', 4)[3])
	else:
		size = 0
		for root, dirs, files in os.walk(path):
			for name in files:
				size += os.path.getsize(os.path.join(root, name))
	return size

def summary(feed):
	if feed.summary:
		return feed.get_name() + ' - ' + feed.summary
	return feed.get_name()

def get_selected_paths(tree_view):
	model, paths = tree_view.get_selection().get_selected_rows()
	return paths

def all_children(model, iter):
	"make a python generator out of the children of `iter`"
	iter = model.iter_children(iter)
	while iter:
		yield iter
		iter = model.iter_next(iter)

# Responses
DELETE = 0
SAFE_MODE = False # really delete things
#SAFE_MODE = True # print deletes, instead of performing them

class CachedFeed(object):
	def __init__(self, uri, size):
		self.uri = uri
		self.size = size

	def delete(self):
		if not os.path.isabs(self.uri):
			cached_iface = basedir.load_first_cache(namespaces.config_site,
					'interfaces', model.escape(self.uri))
			if cached_iface:
				if SAFE_MODE:
					print("Delete", cached_iface)
				else:
					os.unlink(cached_iface)
		user_overrides = basedir.load_first_config(namespaces.config_site,
					namespaces.config_prog,
					'interfaces', model._pretty_escape(self.uri))
		if user_overrides:
			if SAFE_MODE:
				print("Delete", user_overrides)
			else:
				os.unlink(user_overrides)
	
	def __cmp__(self, other):
		return self.uri.__cmp__(other.uri)

class ValidFeed(CachedFeed):
	def __init__(self, feed, size):
		CachedFeed.__init__(self, feed.url, size)
		self.feed = feed
		self.in_cache = []

	def delete_children(self):
		deletable = self.deletable_children()
		undeletable = list(filter(lambda child: not child.may_delete, self.in_cache))
		# the only undeletable items we expect to encounter are LocalImplementations
		unexpected_undeletable = list(filter(lambda child: not isinstance(child, LocalImplementation), undeletable))
		assert not unexpected_undeletable, "unexpected undeletable items!: %r" % (unexpected_undeletable,)
		[child.delete() for child in deletable]

	def delete(self):
		self.delete_children()
		super(ValidFeed, self).delete()

	def append_to(self, model, iter):
		iter2 = model.append(iter, extract_columns(
			name=self.feed.get_name(),
			uri=self.uri,
			tooltip=self.feed.summary,
			object=self))
		for cached_impl in self.in_cache:
			cached_impl.append_to(model, iter2)

	def launch(self, explorer):
		os.spawnlp(os.P_NOWAIT, '0launch', '0launch', '--gui', self.uri)
	
	def copy_uri(self, explorer):
		clipboard = gtk.clipboard_get()
		clipboard.set_text(self.uri)
		primary = gtk.clipboard_get('PRIMARY')
		primary.set_text(self.uri)
	
	def deletable_children(self):
		return list(filter(lambda child: child.may_delete, self.in_cache))
	
	def prompt_delete(self, cache_explorer):
		description = "\"%s\"" % (self.feed.get_name(),)
		num_children = len(self.deletable_children())
		if self.in_cache:
			description += _(" (and %s %s)") % (num_children, _("implementation") if num_children == 1 else _("implementations"))
		if warn(_("Really delete %s?") % (description,), parent=cache_explorer.window):
			self.delete()
			return ACTION_REMOVE
	
	menu_items = [(_('Launch with GUI'), launch),
		      (_('Copy URI'), copy_uri),
		      (_('Delete'), prompt_delete)]

class RemoteFeed(ValidFeed):
	may_delete = True

class LocalFeed(ValidFeed):
	may_delete = False

class InvalidFeed(CachedFeed):
	may_delete = True

	def __init__(self, uri, ex, size):
		CachedFeed.__init__(self, uri, size)
		self.ex = ex

	def append_to(self, model, iter):
		model.append(iter, extract_columns(
			name=self.uri.rsplit('/', 1)[-1],
			uri=self.uri,
			size=self.size,
			tooltip=self.ex,
			object=self))
	
class LocalImplementation(object):
	may_delete = False

	def __init__(self, impl):
		self.impl = impl

	def append_to(self, model, iter):
		model.append(iter, extract_columns(
			name=self.impl.local_path,
			tooltip=_('This is a local version, not held in the cache.'),
			object=self))


class CachedImplementation(object):
	may_delete = True

	def __init__(self, cache_dir, digest):
		self.impl_path = os.path.join(cache_dir, digest)
		self.size = get_size(self.impl_path)
		self.digest = digest

	def delete(self):
		if SAFE_MODE:
			print("Delete", self.impl_path)
		else:
			support.ro_rmtree(self.impl_path)
	
	def open_rox(self, explorer):
		os.spawnlp(os.P_WAIT, '0launch', '0launch', ROX_IFACE, '-d', self.impl_path)
	
	def verify(self, explorer):
		try:
			manifest.verify(self.impl_path)
		except BadDigest as ex:
			box = gtk.MessageDialog(None, 0,
						gtk.MESSAGE_WARNING, gtk.BUTTONS_OK, str(ex))
			if ex.detail:
				swin = gtk.ScrolledWindow()
				buffer = gtk.TextBuffer()
				mono = buffer.create_tag('mono', family = 'Monospace')
				buffer.insert_with_tags(buffer.get_start_iter(), ex.detail, mono)
				text = gtk.TextView(buffer)
				text.set_editable(False)
				text.set_cursor_visible(False)
				swin.add(text)
				swin.set_shadow_type(gtk.SHADOW_IN)
				swin.set_border_width(4)
				box.vbox.pack_start(swin)
				swin.show_all()
				box.set_resizable(True)
		else:
			box = gtk.MessageDialog(None, 0,
						gtk.MESSAGE_INFO, gtk.BUTTONS_OK,
						_('Contents match digest; nothing has been changed.'))
		box.run()
		box.destroy()
	
	def prompt_delete(self, explorer):
		if warn(_("Really delete implementation?"), parent=explorer.window):
			self.delete()
			return ACTION_REMOVE

	if sys.version_info[0] > 2:
		def __lt__(self, other):
			return self.digest < other.digest

		def __eq__(self, other):
			return self.digest == other.digest

	menu_items = [(_('Open in ROX-Filer'), open_rox),
		      (_('Verify integrity'), verify),
		      (_('Delete'), prompt_delete)]

class UnusedImplementation(CachedImplementation):
	def append_to(self, model, iter):
		model.append(iter, extract_columns(
			name=self.digest,
			size=self.size,
			tooltip=self.impl_path,
			object=self))

class KnownImplementation(CachedImplementation):
	def __init__(self, cached_iface, cache_dir, impl, impl_size, digest):
		CachedImplementation.__init__(self, cache_dir, digest)
		self.cached_iface = cached_iface
		self.impl = impl
		self.size = impl_size
	
	def delete(self):
		if SAFE_MODE:
			print("Delete", self.impl)
		else:
			CachedImplementation.delete(self)
			self.cached_iface.in_cache.remove(self)

	def append_to(self, model, iter):
		impl = self.impl
		label = _('Version %(implementation_version)s (%(arch)s)') % {
				'implementation_version': impl.get_version(),
				'arch': impl.arch or 'any platform'}

		model.append(iter, extract_columns(
			name=label,
			size=self.size,
			tooltip=self.impl_path,
			object=self))

	def __cmp__(self, other):
		if hasattr(other, 'impl'):
			return self.impl.__cmp__(other.impl)
		return -1

	if sys.version_info[0] > 2:
		def __lt__(self, other):
			return self.impl.__lt__(other.impl)

		def __eq__(self, other):
			return self.impl.__eq__(other.impl)

class CacheExplorer(object):
	"""A graphical interface for viewing the cache and deleting old items."""

	def __init__(self, iface_cache):
		widgets = gtkutils.Template(os.path.join(os.path.dirname(__file__), 'cache.ui'), 'cache')
		self.window = window = widgets.get_widget('cache')
		window.set_default_size(gtk.gdk.screen_width() / 2, gtk.gdk.screen_height() / 2)
		self.iface_cache = iface_cache

		# Model
		self.raw_model = gtk.TreeStore(*Column.column_types())
		self.view_model = self.raw_model.filter_new()
		self.model.set_sort_column_id(URI.idx, gtk.SORT_ASCENDING)
		self.tree_view = widgets.get_widget('treeview')
		Column.add_all(self.tree_view)

		# Sort / Filter options:

		def init_combo(combobox, items, on_select):
			liststore = gtk.ListStore(str)
			combobox.set_model(liststore)
			cell = gtk.CellRendererText()
			combobox.pack_start(cell, True)
			combobox.add_attribute(cell, 'text', 0)
			for item in items:
				combobox.append_text(item[0])
			combobox.set_active(0)
			def _on_select(*a):
				selected_item = combobox.get_active()
				on_select(selected_item)
			combobox.connect('changed', lambda *a: on_select(items[combobox.get_active()]))

		def set_sort_order(sort_order):
			#print "SORT: %r" % (sort_order,)
			name, column, order = sort_order
			self.model.set_sort_column_id(column.idx, order)
		self.sort_combo = widgets.get_widget('sort_combo')
		init_combo(self.sort_combo, SORT_OPTIONS, set_sort_order)

		def set_filter(f):
			#print "FILTER: %r" % (f,)
			description, filter_func = f
			self.view_model = self.model.filter_new()
			self.view_model.set_visible_func(filter_func)
			self.tree_view.set_model(self.view_model)
			self.set_initial_expansion()
		self.filter_combo = widgets.get_widget('filter_combo')
		init_combo(self.filter_combo, FILTER_OPTIONS, set_filter)

		def button_press(tree_view, bev):
			if bev.button != 3:
				return False
			pos = tree_view.get_path_at_pos(int(bev.x), int(bev.y))
			if not pos:
				return False
			path, col, x, y = pos
			obj = self.model[path][ITEM_OBJECT.idx]
			if obj and hasattr(obj, 'menu_items'):
				popup_menu(bev, obj, model=self.model, path=path, cache_explorer=self)
		self.tree_view.connect('button-press-event', button_press)

		# Responses
		window.set_default_response(gtk.RESPONSE_CLOSE)

		selection = self.tree_view.get_selection()
		def selection_changed(selection):
			any_selected = False
			for x in get_selected_paths(self.tree_view):
				obj = self.model[x][ITEM_OBJECT.idx]
				if obj is None or not obj.may_delete:
					window.set_response_sensitive(DELETE, False)
					return
				any_selected = True
			window.set_response_sensitive(DELETE, any_selected)
		selection.set_mode(gtk.SELECTION_MULTIPLE)
		selection.connect('changed', selection_changed)
		selection_changed(selection)

		def response(dialog, resp):
			if resp == gtk.RESPONSE_CLOSE:
				window.destroy()
			elif resp == gtk.RESPONSE_HELP:
				cache_help.display()
			elif resp == DELETE:
				self._delete()
		window.connect('response', response)
	
	@property
	def model(self):
		return self.view_model.get_model()

	def _delete(self):
		errors = []

		model = self.model
		paths = get_selected_paths(self.tree_view)
		paths.reverse()
		for path in paths:
			item = model[path][ITEM_OBJECT.idx]
			assert item.delete
			try:
				item.delete()
			except OSError as ex:
				errors.append(str(ex))
			else:
				model.remove(model.get_iter(path))
		self._update_sizes()

		if errors:
			gtkutils.show_message_box(self.window, _("Failed to delete:\n%s") % '\n'.join(errors))

	def show(self):
		"""Display the window and scan the caches to populate it."""
		self.window.show()
		self.window.get_window().set_cursor(gtkutils.get_busy_pointer())
		gtk.gdk.flush()
		# (async so that the busy pointer works on GTK 3)
		@tasks.async
		def populate():
			populate = self._populate_model()
			yield populate
			try:
				tasks.check(populate)
			except:
				import logging
				logging.warn("fail", exc_info = True)
				raise
			# (we delay until here because inserting with the view set is very slow)
			self.tree_view.set_model(self.view_model)
			self.set_initial_expansion()
		return populate()
	
	def set_initial_expansion(self):
		model = self.model
		try:
			i = model.get_iter_root()
			while i:
				# expand only "Feeds"
				if model[i][ITEM_OBJECT.idx] is SECTION_INTERFACES:
					self.tree_view.expand_row(model.get_path(i), False)
				i = model.iter_next(i)
		finally:
			self.window.get_window().set_cursor(None)

	@tasks.async
	def _populate_model(self):
		# Find cached implementations

		unowned = {}	# Impl ID -> Store
		duplicates = [] # TODO

		for s in self.iface_cache.stores.stores:
			if os.path.isdir(s.dir):
				for id in os.listdir(s.dir):
					if id in unowned:
						duplicates.append(id)
					unowned[id] = s

		ok_feeds = []
		error_feeds = []

		# Look through cached feeds for implementation owners
		all_interfaces = self.iface_cache.list_all_interfaces()
		all_feeds = {}
		for uri in all_interfaces:
			try:
				iface = self.iface_cache.get_interface(uri)
			except Exception as ex:
				error_feeds.append((uri, str(ex), 0))
			else:
				all_feeds.update(self.iface_cache.get_feeds(iface))

		for url, feed in all_feeds.items():
			if not feed: continue
			yield
			feed_size = 0
			try:
				if url != feed.url:
					# (e.g. for .new feeds)
					raise Exception('Incorrect URL for feed (%s vs %s)' % (url, feed.url))

				if os.path.isabs(url):
					cached_feed = url
					feed_type = LocalFeed
				else:
					feed_type = RemoteFeed
					cached_feed = basedir.load_first_cache(namespaces.config_site,
							'interfaces', model.escape(url))
				user_overrides = basedir.load_first_config(namespaces.config_site,
							namespaces.config_prog,
							'interfaces', model._pretty_escape(url))

				feed_size = size_if_exists(cached_feed) + size_if_exists(user_overrides)
			except Exception as ex:
				error_feeds.append((url, str(ex), feed_size))
			else:
				cached_feed = feed_type(feed, feed_size)
				for impl in feed.implementations.values():
					if impl.local_path:
						cached_feed.in_cache.append(LocalImplementation(impl))
					for digest in impl.digests:
						if digest in unowned:
							cached_dir = unowned[digest].dir
							impl_path = os.path.join(cached_dir, digest)
							impl_size = get_size(impl_path)
							cached_feed.in_cache.append(KnownImplementation(cached_feed, cached_dir, impl, impl_size, digest))
							del unowned[digest]
				cached_feed.in_cache.sort()
				ok_feeds.append(cached_feed)

		if error_feeds:
			iter = SECTION_INVALID_INTERFACES.append_to(self.raw_model)
			for uri, ex, size in error_feeds:
				item = InvalidFeed(uri, ex, size)
				item.append_to(self.raw_model, iter)

		unowned_sizes = []
		local_dir = os.path.join(basedir.xdg_cache_home, '0install.net', 'implementations')
		for id in unowned:
			if unowned[id].dir == local_dir:
				impl = UnusedImplementation(local_dir, id)
				unowned_sizes.append((impl.size, impl))
		if unowned_sizes:
			iter = SECTION_UNOWNED_IMPLEMENTATIONS.append_to(self.raw_model)
			for size, item in unowned_sizes:
				item.append_to(self.raw_model, iter)

		if ok_feeds:
			iter = SECTION_INTERFACES.append_to(self.raw_model)
			for item in ok_feeds:
				yield
				item.append_to(self.raw_model, iter)
		self._update_sizes()
	
	def _update_sizes(self):
		"""Set TOTAL_SIZE and PRETTY_SIZE to the total size, including all children."""
		m = self.raw_model
		def update(itr):
			total = m[itr][SELF_SIZE.idx]
			total += sum(map(update, all_children(m, itr)))
			m[itr][PRETTY_SIZE.idx] = support.pretty_size(total) if total else '-'
			m[itr][TOTAL_SIZE.idx] = total
			return total
		itr = m.get_iter_root()
		while itr:
			update(itr)
			itr = m.iter_next(itr)


SORT_OPTIONS = [
	('URI', URI, gtk.SORT_ASCENDING),
	('Name', NAME, gtk.SORT_ASCENDING),
	('Size', TOTAL_SIZE, gtk.SORT_DESCENDING),
]

def init_filters():
	def filter_only(filterable_types, filter_func):
		def _filter(model, iter):
			obj = model.get_value(iter, ITEM_OBJECT.idx)
			if any((isinstance(obj, t) for t in filterable_types)):
				result = filter_func(model, iter)
				return result
			return True
		return _filter

	def not_(func):
		return lambda *a: not func(*a)

	def is_local_feed(model, iter):
		return isinstance(model[iter][ITEM_OBJECT.idx], LocalFeed)

	def has_implementations(model, iter):
		return model.iter_has_child(iter)

	return [
		('All', lambda *a: True),
		('Feeds with implementations', filter_only([ValidFeed], has_implementations)),
		('Feeds without implementations', filter_only([ValidFeed], not_(has_implementations))),
		('Local Feeds', filter_only([ValidFeed], is_local_feed)),
		('Remote Feeds', filter_only([ValidFeed], not_(is_local_feed))),
	]
FILTER_OPTIONS = init_filters()


cache_help = help_box.HelpBox(_("Cache Explorer Help"),
(_('Overview'), '\n' +
_("""When you run a program using Zero Install, it downloads the program's 'feed' file, \
which gives information about which versions of the program are available. This feed \
file is stored in the cache to save downloading it next time you run the program.

When you have chosen which version (implementation) of the program you want to \
run, Zero Install downloads that version and stores it in the cache too. Zero Install lets \
you have many different versions of each program on your computer at once. This is useful, \
since it lets you use an old version if needed, and different programs may need to use \
different versions of libraries in some cases.

The cache viewer shows you all the feeds and implementations in your cache. \
This is useful to find versions you don't need anymore, so that you can delete them and \
free up some disk space.""")),

(_('Invalid feeds'), '\n' +
_("""The cache viewer gets a list of all feeds in your cache. However, some may not \
be valid; they are shown in the 'Invalid feeds' section. It should be fine to \
delete these. An invalid feed may be caused by a local feed that no longer \
exists or by a failed attempt to download a feed (the name ends in '.new').""")),

(_('Unowned implementations and temporary files'), '\n' +
_("""The cache viewer searches through all the feeds to find out which implementations \
they use. If no feed uses an implementation, it is shown in the 'Unowned implementations' \
section.

Unowned implementations can result from old versions of a program no longer being listed \
in the feed file. Temporary files are created when unpacking an implementation after \
downloading it. If the archive is corrupted, the unpacked files may be left there. Unless \
you are currently unpacking new programs, it should be fine to delete everything in this \
section.""")),

(_('Feeds'), '\n' +
_("""All remaining feeds are listed in this section. You may wish to delete old versions of \
certain programs. Deleting a program which you may later want to run will require it to be downloaded \
again. Deleting a version of a program which is currently running may cause it to crash, so be careful!""")))
