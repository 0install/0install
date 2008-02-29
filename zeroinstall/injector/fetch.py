"""
Downloads feeds, keys, packages and icons.
"""

# Copyright (C) 2008, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from logging import info, debug, warn

from zeroinstall.support import tasks, basedir
from zeroinstall.injector.namespaces import XMLNS_IFACE, config_site
from zeroinstall.injector.model import DownloadSource, Recipe, SafeException, network_offline, escape
from zeroinstall.injector.iface_cache import PendingFeed

class Fetcher(object):
	"""Downloads and stores various things.
	@ivar handler: handler to use for user-interaction
	@type handler: L{handler.Handler}"""
	__slots__ = ['handler']

	def __init__(self, handler):
		self.handler = handler

	@tasks.async
	def cook(self, required_digest, recipe, stores, force = False, impl_hint = None):
		"""Follow a Recipe.
		@param impl_hint: the Implementation this is for (if any) as a hint for the GUI
		@see: L{download_impl} uses this method when appropriate"""
		# Maybe we're taking this metaphor too far?

		# Start downloading all the ingredients.
		downloads = {}	# Downloads that are not yet successful
		streams = {}	# Streams collected from successful downloads

		# Start a download for each ingredient
		blockers = []
		for step in recipe.steps:
			blocker, stream = self.download_archive(step, force = force, impl_hint = impl_hint)
			assert stream
			blockers.append(blocker)
			streams[step] = stream

		while blockers:
			yield blockers
			tasks.check(blockers)
			blockers = [b for b in blockers if not b.happened]

		from zeroinstall.zerostore import unpack

		# Create an empty directory for the new implementation
		store = stores.stores[0]
		tmpdir = store.get_tmp_dir_for(required_digest)
		try:
			# Unpack each of the downloaded archives into it in turn
			for step in recipe.steps:
				stream = streams[step]
				stream.seek(0)
				unpack.unpack_archive_over(step.url, stream, tmpdir, step.extract)
			# Check that the result is correct and store it in the cache
			store.check_manifest_and_rename(required_digest, tmpdir)
			tmpdir = None
		finally:
			# If unpacking fails, remove the temporary directory
			if tmpdir is not None:
				from zeroinstall import support
				support.ro_rmtree(tmpdir)

	def download_and_import_feed(self, feed_url, iface_cache, force = False):
		"""Download the feed, download any required keys, confirm trust if needed and import.
		@param feed_url: the feed to be downloaded
		@type feed_url: str
		@param iface_cache: cache in which to store the feed
		@type iface_cache: L{iface_cache.IfaceCache}
		@param force: whether to abort and restart an existing download"""
		
		debug("download_and_import_feed %s (force = %d)", feed_url, force)
		assert not feed_url.startswith('/')

		dl = self.handler.get_download(feed_url, force = force, hint = feed_url)

		@tasks.named_async("fetch_feed " + feed_url)
		def fetch_feed():
			stream = dl.tempfile

			yield dl.downloaded
			tasks.check(dl.downloaded)

			pending = PendingFeed(feed_url, stream)
			iface_cache.add_pending(pending)

			keys_downloaded = tasks.Task(pending.download_keys(self.handler, feed_hint = feed_url), "download keys for " + feed_url)
			yield keys_downloaded.finished
			tasks.check(keys_downloaded.finished)

			iface = iface_cache.get_interface(pending.url)
			if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
				blocker = self.handler.confirm_trust_keys(iface, pending.sigs, pending.new_xml)
				if blocker:
					yield blocker
					tasks.check(blocker)
				if not iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml):
					raise SafeException("No signing keys trusted; not importing")

		return fetch_feed()

	def download_impl(self, impl, retrieval_method, stores, force = False):
		"""Download an implementation.
		@param impl: the selected implementation
		@type impl: L{model.ZeroInstallImplementation}
		@param retrieval_method: a way of getting the implementation (e.g. an Archive or a Recipe)
		@type retrieval_method: L{model.RetrievalMethod}
		@param stores: where to store the downloaded implementation
		@type stores: L{zerostore.Stores}
		@param force: whether to abort and restart an existing download
		@rtype: L{tasks.Blocker}"""
		assert impl
		assert retrieval_method

		from zeroinstall.zerostore import manifest
		alg = impl.id.split('=', 1)[0]
		if alg not in manifest.algorithms:
			raise SafeException("Unknown digest algorithm '%s' for '%s' version %s" %
					(alg, impl.feed.get_name(), impl.get_version()))

		@tasks.async
		def download_impl():
			if isinstance(retrieval_method, DownloadSource):
				blocker, stream = self.download_archive(retrieval_method, force = force, impl_hint = impl)
				yield blocker
				tasks.check(blocker)

				stream.seek(0)
				self._add_to_cache(stores, retrieval_method, stream)
			elif isinstance(retrieval_method, Recipe):
				blocker = self.cook(impl.id, retrieval_method, stores, force, impl_hint = impl)
				yield blocker
				tasks.check(blocker)
			else:
				raise Exception("Unknown download type for '%s'" % retrieval_method)

			self.handler.impl_added_to_store(impl)
		return download_impl()
	
	def _add_to_cache(self, stores, retrieval_method, stream):
		assert isinstance(retrieval_method, DownloadSource)
		required_digest = retrieval_method.implementation.id
		url = retrieval_method.url
		stores.add_archive_to_cache(required_digest, stream, retrieval_method.url, retrieval_method.extract,
						 type = retrieval_method.type, start_offset = retrieval_method.start_offset or 0)

	def download_archive(self, download_source, force = False, impl_hint = None):
		"""Fetch an archive. You should normally call L{download_impl}
		instead, since it handles other kinds of retrieval method too."""
		from zeroinstall.zerostore import unpack
		mime_type = download_source.type
		if not mime_type:
			mime_type = unpack.type_from_url(download_source.url)
		if not mime_type:
			raise SafeException("No 'type' attribute on archive, and I can't guess from the name (%s)" % download_source.url)
		unpack.check_type_ok(mime_type)
		dl = self.handler.get_download(download_source.url, force = force, hint = impl_hint)
		dl.expected_size = download_source.size + (download_source.start_offset or 0)
		return (dl.downloaded, dl.tempfile)

	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon or we are offline, do nothing.
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		debug("download_icon %s (force = %d)", interface, force)

		# Find a suitable icon to download
		for icon in interface.get_metadata(XMLNS_IFACE, 'icon'):
			type = icon.getAttribute('type')
			if type != 'image/png':
				debug('Skipping non-PNG icon')
				continue
			source = icon.getAttribute('href')
			if source:
				break
			warn('Missing "href" attribute on <icon> in %s', interface)
		else:
			info('No PNG icons found in %s', interface)
			return

		dl = self.handler.get_download(source, force = force, hint = interface)

		@tasks.async
		def download_and_add_icon():
			stream = dl.tempfile
			yield dl.downloaded
			try:
				tasks.check(dl.downloaded)
				stream.seek(0)

				import shutil
				icons_cache = basedir.save_cache_path(config_site, 'interface_icons')
				icon_file = file(os.path.join(icons_cache, escape(interface.uri)), 'w')
				shutil.copyfileobj(stream, icon_file)
			except Exception, ex:
				self.handler.report_error(ex)

		return download_and_add_icon()

	def download_impls(self, implementations, stores):
		"""Download the given implementations, choosing a suitable retrieval method for each."""
		blockers = []

		to_download = []
		for impl in implementations:
			debug("start_downloading_impls: for %s get %s", impl.feed, impl)
			source = self.get_best_source(impl)
			if not source:
				raise SafeException("Implementation " + impl.id + " of "
					"interface " + impl.feed.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!)")
			to_download.append((impl, source))

		for impl, source in to_download:
			blockers.append(self.download_impl(impl, source, stores))

		if not blockers:
			return None

		@tasks.async
		def download_impls(blockers):
			# Record the first error log the rest
			error = []
			def dl_error(ex, tb = None):
				if error:
					self.handler.report_error(ex)
				else:
					error.append(ex)
			while blockers:
				yield blockers
				tasks.check(blockers, dl_error)

				blockers = [b for b in blockers if not b.happened]
			if error:
				raise error[0]

		return download_impls(blockers)

	def get_best_source(self, impl):
		"""Return the best download source for this implementation.
		@rtype: L{model.RetrievalMethod}"""
		if impl.download_sources:
			return impl.download_sources[0]
		return None

