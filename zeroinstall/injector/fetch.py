"""
Downloads feeds, keys, packages and icons.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import os, sys

from zeroinstall import support
from zeroinstall.support import tasks, basedir, portable_rename
from zeroinstall.injector.namespaces import XMLNS_IFACE, config_site
from zeroinstall.injector import model
from zeroinstall.injector.model import Recipe, SafeException, escape, DistributionSource
from zeroinstall.injector.iface_cache import PendingFeed, ReplayAttack
from zeroinstall.injector.handler import NoTrustedKeys
from zeroinstall.injector import download

def _escape_slashes(path):
	"""@type path: str
	@rtype: str"""
	return path.replace('/', '%23')

def _get_feed_dir(feed):
	"""The algorithm from 0mirror.
	@type feed: str
	@rtype: str"""
	if '#' in feed:
		raise SafeException(_("Invalid URL '%s'") % feed)
	scheme, rest = feed.split('://', 1)
	assert '/' in rest, "Missing / in %s" % feed
	domain, rest = rest.split('/', 1)
	for x in [scheme, domain, rest]:
		if not x or x.startswith('.'):
			raise SafeException(_("Invalid URL '%s'") % feed)
	return '/'.join(['feeds', scheme, domain, _escape_slashes(rest)])

class KeyInfoFetcher(object):
	"""Fetches information about a GPG key from a key-info server.
	See L{Fetcher.fetch_key_info} for details.
	@since: 0.42

	Example:

	>>> kf = KeyInfoFetcher(fetcher, 'https://server', fingerprint)
	>>> while True:
		print kf.info
		if kf.blocker is None: break
		print kf.status
		yield kf.blocker
	"""
	def __init__(self, fetcher, server, fingerprint):
		"""@type fetcher: L{Fetcher}
		@type server: str
		@type fingerprint: str"""
		self.fingerprint = fingerprint
		self.info = []
		self.blocker = None

		if server is None: return

		self.status = _('Fetching key information from %s...') % server

		dl = fetcher.download_url(server + '/key/' + fingerprint)

		from xml.dom import minidom

		@tasks.async
		def fetch_key_info():
			tempfile = dl.tempfile
			try:
				yield dl.downloaded
				self.blocker = None
				tasks.check(dl.downloaded)
				tempfile.seek(0)
				doc = minidom.parse(tempfile)
				if doc.documentElement.localName != 'key-lookup':
					raise SafeException(_('Expected <key-lookup>, not <%s>') % doc.documentElement.localName)
				self.info += doc.documentElement.childNodes
			except Exception as ex:
				doc = minidom.parseString('<item vote="bad"/>')
				root = doc.documentElement
				root.appendChild(doc.createTextNode(_('Error getting key information: %s') % ex))
				self.info.append(root)
			finally:
				tempfile.close()

		self.blocker = fetch_key_info()

class Fetcher(object):
	"""Downloads and stores various things.
	@ivar config: used to get handler, iface_cache and stores
	@type config: L{config.Config}
	@ivar key_info: caches information about GPG keys
	@type key_info: {str: L{KeyInfoFetcher}}
	"""
	__slots__ = ['config', 'key_info', '_scheduler', 'external_store', 'external_fetcher']

	def __init__(self, config):
		"""@type config: L{zeroinstall.injector.config.Config}"""
		assert config.handler, "API change!"
		self.config = config
		self.key_info = {}
		self._scheduler = None
		self.external_store = os.environ.get('ZEROINSTALL_EXTERNAL_STORE')
		self.external_fetcher = os.environ.get('ZEROINSTALL_EXTERNAL_FETCHER')

	@property
	def handler(self):
		return self.config.handler

	@property
	def scheduler(self):
		if self._scheduler is None:
			from . import scheduler
			self._scheduler = scheduler.DownloadScheduler()
		return self._scheduler

	# (force is deprecated and ignored)
	@tasks.async
	def cook(self, required_digest, recipe, stores, force = False, impl_hint = None, dry_run = False, may_use_mirror = True):
		"""Follow a Recipe.
		@type required_digest: str
		@type recipe: L{Recipe}
		@type stores: L{zeroinstall.zerostore.Stores}
		@type force: bool
		@param impl_hint: the Implementation this is for (as a hint for the GUI, and to allow local files)
		@type dry_run: bool
		@type may_use_mirror: bool
		@see: L{download_impl} uses this method when appropriate"""
		# Maybe we're taking this metaphor too far?

		# Start a download for each ingredient
		blockers = []
		steps = []
		try:
			for stepdata in recipe.steps:
				cls = StepRunner.class_for(stepdata)
				step = cls(stepdata, impl_hint = impl_hint, may_use_mirror = may_use_mirror)
				step.prepare(self, blockers)
				steps.append(step)

			while blockers:
				yield blockers
				tasks.check(blockers)
				blockers = [b for b in blockers if not b.happened]

			if self.external_store:
				# Note: external_store will not work with non-<archive> steps.
				streams = [step.stream for step in steps]
				self._add_to_external_store(required_digest, recipe.steps, streams)
			else:
				# Create an empty directory for the new implementation
				store = stores.stores[0]
				tmpdir = store.get_tmp_dir_for(required_digest)
				try:
					# Unpack each of the downloaded archives into it in turn
					for step in steps:
						step.apply(tmpdir)
					# Check that the result is correct and store it in the cache
					stores.check_manifest_and_rename(required_digest, tmpdir, dry_run=dry_run)
					tmpdir = None
				finally:
					# If unpacking fails, remove the temporary directory
					if tmpdir is not None:
						support.ro_rmtree(tmpdir)
		finally:
			for step in steps:
				try:
					step.close()
				except IOError as ex:
					# Can get "close() called during
					# concurrent operation on the same file
					# object." if we're unlucky (Python problem).
					logger.info("Failed to close: %s", ex)

	def _get_mirror_url(self, feed_url, resource):
		"""Return the URL of a mirror for this feed.
		@type feed_url: str
		@type resource: str
		@rtype: str"""
		if self.config.mirror is None:
			return None
		if feed_url.startswith('http://') or feed_url.startswith('https://'):
			if support.urlparse(feed_url).hostname == 'localhost':
				return None
			return '%s/%s/%s' % (self.config.mirror, _get_feed_dir(feed_url), resource)
		return None

	def get_feed_mirror(self, url):
		"""Return the URL of a mirror for this feed.
		@type url: str
		@rtype: str"""
		return self._get_mirror_url(url, 'latest.xml')

	def _get_archive_mirror(self, source):
		"""@type source: L{model.DownloadSource}
		@rtype: str"""
		if self.config.mirror is None:
			return None
		if support.urlparse(source.url).hostname == 'localhost':
			return None
		if sys.version_info[0] > 2:
			from urllib.parse import quote
		else:
			from urllib import quote
		return '{mirror}/archive/{archive}'.format(
				mirror = self.config.mirror,
				archive = quote(source.url.replace('/', '#'), safe = ''))

	def _get_impl_mirror(self, impl):
		"""@type impl: L{zeroinstall.injector.model.ZeroInstallImplementation}
		@rtype: str"""
		return self._get_mirror_url(impl.feed.url, 'impl/' + _escape_slashes(impl.id))

	@tasks.async
	def get_packagekit_feed(self, feed_url):
		"""Send a query to PackageKit (if available) for information about this package.
		On success, the result is added to iface_cache.
		@type feed_url: str"""
		assert feed_url.startswith('distribution:'), feed_url
		master_feed = self.config.iface_cache.get_feed(feed_url.split(':', 1)[1])
		if master_feed:
			fetch = self.config.iface_cache.distro.fetch_candidates(master_feed)
			if fetch:
				yield fetch
				tasks.check(fetch)

			# Force feed to be regenerated with the new information
			self.config.iface_cache.get_feed(feed_url, force = True)

	def download_and_import_feed(self, feed_url, iface_cache = None):
		"""Download the feed, download any required keys, confirm trust if needed and import.
		@param feed_url: the feed to be downloaded
		@type feed_url: str
		@param iface_cache: (deprecated)
		@type iface_cache: L{zeroinstall.injector.iface_cache.IfaceCache} | None
		@rtype: L{zeroinstall.support.tasks.Blocker}"""
		from .download import DownloadAborted

		assert iface_cache is None or iface_cache is self.config.iface_cache

		if not self.config.handler.dry_run:
			try:
				self.config.iface_cache.mark_as_checking(feed_url)
			except OSError as ex:
				retval = tasks.Blocker("mark_as_checking")
				retval.trigger(exception = (ex, None))
				return retval
		
		logger.debug(_("download_and_import_feed %(url)s"), {'url': feed_url})
		assert not os.path.isabs(feed_url)

		if feed_url.startswith('distribution:'):
			return self.get_packagekit_feed(feed_url)

		primary = self._download_and_import_feed(feed_url, use_mirror = False, timeout = 5)

		@tasks.named_async("monitor feed downloads for " + feed_url)
		def wait_for_downloads(primary):
			# Download just the upstream feed, unless it takes too long...
			timeout = primary.dl.timeout
			yield primary, timeout
			tasks.check(timeout)

			try:
				tasks.check(primary)
				if primary.happened:
					return		# OK, primary succeeded!
				# OK, maybe it's just being slow...
				logger.info("Feed download from %s is taking a long time.", feed_url)
				primary_ex = None
			except NoTrustedKeys as ex:
				raise			# Don't bother trying the mirror if we have a trust problem
			except ReplayAttack as ex:
				raise			# Don't bother trying the mirror if we have a replay attack
			except DownloadAborted as ex:
				raise			# Don't bother trying the mirror if the user cancelled
			except SafeException as ex:
				# Primary failed
				primary = None
				primary_ex = ex
				logger.warning(_("Feed download from %(url)s failed: %(exception)s"), {'url': feed_url, 'exception': ex})

			# Start downloading from mirror...
			mirror = self._download_and_import_feed(feed_url, use_mirror = True)

			# Wait until both mirror and primary tasks are complete...
			while True:
				blockers = list(filter(None, [primary, mirror]))
				if not blockers:
					break
				yield blockers

				if primary:
					try:
						tasks.check(primary)
						if primary.happened:
							primary = None
							# No point carrying on with the mirror once the primary has succeeded
							if mirror:
								logger.info(_("Primary feed download succeeded; aborting mirror download for %s") % feed_url)
								mirror.dl.abort()
					except SafeException as ex:
						primary = None
						primary_ex = ex
						logger.info(_("Feed download from %(url)s failed; still trying mirror: %(exception)s"), {'url': feed_url, 'exception': ex})

				if mirror:
					try:
						tasks.check(mirror)
						if mirror.happened:
							mirror = None
							if primary_ex:
								# We already warned; no need to raise an exception too,
								# as the mirror download succeeded.
								primary_ex = None
					except ReplayAttack as ex:
						logger.info(_("Version from mirror is older than cached version; ignoring it: %s"), ex)
						mirror = None
						primary_ex = None
					except SafeException as ex:
						logger.info(_("Mirror download failed: %s"), ex)
						mirror = None

			if primary_ex:
				raise primary_ex

		return wait_for_downloads(primary)

	def _download_and_import_feed(self, feed_url, use_mirror, timeout = None):
		"""Download and import a feed.
		@type feed_url: str
		@param use_mirror: False to use primary location; True to use mirror.
		@type use_mirror: bool
		@param timeout: callback to invoke when the download actually starts
		@rtype: L{zeroinstall.support.tasks.Blocker}"""
		if use_mirror:
			url = self.get_feed_mirror(feed_url)
			if url is None: return None
			logger.info(_("Trying mirror server for feed %s") % feed_url)
		else:
			url = feed_url

		if self.config.handler.dry_run:
			print(_("[dry-run] downloading feed {url}").format(url = url))
		dl = self.download_url(url, hint = feed_url, timeout = timeout)
		stream = dl.tempfile

		@tasks.named_async("fetch_feed " + url)
		def fetch_feed():
			try:
				yield dl.downloaded
				tasks.check(dl.downloaded)

				pending = PendingFeed(feed_url, stream)

				if use_mirror:
					# If we got the feed from a mirror, get the key from there too
					key_mirror = self.config.mirror + '/keys/'
				else:
					key_mirror = None

				keys_downloaded = tasks.Task(pending.download_keys(self, feed_hint = feed_url, key_mirror = key_mirror), _("download keys for %s") % feed_url)
				yield keys_downloaded.finished
				tasks.check(keys_downloaded.finished)

				dry_run = self.handler.dry_run
				if not self.config.iface_cache.update_feed_if_trusted(pending.url, pending.sigs, pending.new_xml, dry_run = dry_run):
					blocker = self.config.trust_mgr.confirm_keys(pending)
					if blocker:
						yield blocker
						tasks.check(blocker)
					if not self.config.iface_cache.update_feed_if_trusted(pending.url, pending.sigs, pending.new_xml, dry_run = dry_run):
						raise NoTrustedKeys(_("No signing keys trusted; not importing"))
			finally:
				stream.close()

		task = fetch_feed()
		task.dl = dl

		return task

	def fetch_key_info(self, fingerprint):
		"""@type fingerprint: str
		@rtype: L{KeyInfoFetcher}"""
		try:
			return self.key_info[fingerprint]
		except KeyError:
			if self.config.handler.dry_run:
				print(_("[dry-run] asking {url} about key {key}").format(
					url = self.config.key_info_server,
					key = fingerprint))
			self.key_info[fingerprint] = key_info = KeyInfoFetcher(self,
									self.config.key_info_server, fingerprint)
			return key_info

	# (force is deprecated and ignored)
	def download_impl(self, impl, retrieval_method, stores, force = False):
		"""Download an implementation.
		@param impl: the selected implementation
		@type impl: L{model.ZeroInstallImplementation}
		@param retrieval_method: a way of getting the implementation (e.g. an Archive or a Recipe)
		@type retrieval_method: L{model.RetrievalMethod}
		@param stores: where to store the downloaded implementation
		@type stores: L{zerostore.Stores}
		@type force: bool
		@rtype: L{tasks.Blocker}"""
		assert impl
		assert retrieval_method

		if isinstance(retrieval_method, DistributionSource):
			return retrieval_method.install(self.handler)

		from zeroinstall.zerostore import manifest, parse_algorithm_digest_pair
		best = None
		for digest in impl.digests:
			alg_name, digest_value = parse_algorithm_digest_pair(digest)
			alg = manifest.algorithms.get(alg_name, None)
			if alg and (best is None or best.rating < alg.rating):
				best = alg
				required_digest = digest

		if best is None:
			if not impl.digests:
				raise SafeException(_("No <manifest-digest> given for '%(implementation)s' version %(version)s") %
						{'implementation': impl.feed.get_name(), 'version': impl.get_version()})
			raise SafeException(_("Unknown digest algorithms '%(algorithms)s' for '%(implementation)s' version %(version)s") %
					{'algorithms': impl.digests, 'implementation': impl.feed.get_name(), 'version': impl.get_version()})

		@tasks.async
		def download_impl(method):
			original_exception = None
			while True:
				if not isinstance(method, Recipe):
					# turn an individual method into a single-step Recipe
					step = method
					method = Recipe()
					method.steps.append(step)

				try:
					blocker = self.cook(required_digest, method, stores,
							impl_hint = impl,
							dry_run = self.handler.dry_run,
							may_use_mirror = original_exception is None)
					yield blocker
					tasks.check(blocker)
				except download.DownloadError as ex:
					if original_exception:
						logger.info("Error from mirror: %s", ex)
						raise original_exception
					else:
						original_exception = ex
					mirror_url = self._get_impl_mirror(impl)
					if mirror_url is not None:
						logger.info("%s: trying implementation mirror at %s", ex, mirror_url)
						method = model.DownloadSource(impl, mirror_url,
									None, None, type = 'application/x-bzip-compressed-tar')
						continue		# Retry
					raise
				except SafeException as ex:
					raise SafeException("Error fetching {url} {version}: {ex}".format(
						url = impl.feed.url,
						version = impl.get_version(),
						ex = ex))
				break

			self.handler.impl_added_to_store(impl)
		return download_impl(retrieval_method)

	def _add_to_external_store(self, required_digest, steps, streams):
		"""@type required_digest: str"""
		from zeroinstall.zerostore.unpack import type_from_url

		# combine archive path, extract directory and MIME type arguments in an alternating fashion
		paths = map(lambda stream: stream.name, streams)
		extracts = map(lambda step: step.extract or "", steps)
		types = map(lambda step: step.type or type_from_url(step.url), steps)
		args = [None]*(len(paths)+len(extracts)+len(types))
		args[::3] = paths
		args[1::3] = extracts
		args[2::3] = types

		# close file handles to allow external processes access
		for stream in streams:
			stream.close()

		# delegate extracting archives to external tool
		import subprocess
		retval = subprocess.call([self.external_store, "add", required_digest] + args)

		# delete temp files
		for path in paths:
			os.remove(path)

		if retval != 0:
			raise SafeException(_("Extracting with external store failed"))

	def _download_local_file(self, download_source, impl_hint):
		# Relative path
		if impl_hint is None or not impl_hint.feed.local_path:
			raise SafeException(_("Relative URL '{url}' in non-local feed '{feed}'").format(
				url = download_source.url,
				feed = impl_hint.feed))

		local_file = os.path.join(os.path.dirname(impl_hint.feed.local_path), download_source.url)
		try:
			size = os.path.getsize(local_file)
			if size != download_source.size:
				raise SafeException(_("Wrong size for {path}: feed says {expected}, but actually {actual} bytes").format(
					path = local_file,
					expected = download_source.size,
					actual = size))
			return (None, open(local_file, 'rb'))
		except OSError as ex:
			raise SafeException(str(ex))	# (error already includes path)

	# (force is deprecated and ignored)
	def download_archive(self, download_source, force = False, impl_hint = None, may_use_mirror = False):
		"""Fetch an archive. You should normally call L{download_impl}
		instead, since it handles other kinds of retrieval method too.
		It is the caller's responsibility to ensure that the returned stream is closed.
		If impl_hint is from a local feed and the url is relative, just opens the existing file for reading.
		@type download_source: L{model.DownloadSource}
		@type force: bool
		@type may_use_mirror: bool
		@rtype: (L{Blocker} | None, file)"""
		from zeroinstall.zerostore import unpack

		mime_type = download_source.type
		if not mime_type:
			mime_type = unpack.type_from_url(download_source.url)
		if not mime_type:
			raise SafeException(_("No 'type' attribute on archive, and I can't guess from the name (%s)") % download_source.url)
		if not self.external_store:
			unpack.check_type_ok(mime_type)

		if '://' not in download_source.url:
			return self._download_local_file(download_source, impl_hint)

		if may_use_mirror:
			mirror = self._get_archive_mirror(download_source)
		else:
			mirror = None

		if self.config.handler.dry_run:
			print(_("[dry-run] downloading archive {url}").format(url = download_source.url))
		dl = self.download_url(download_source.url, hint = impl_hint, mirror_url = mirror)
		if download_source.size is not None:
			dl.expected_size = download_source.size + (download_source.start_offset or 0)
		# (else don't know sizes for mirrored archives)
		return (dl.downloaded, dl.tempfile)

	def download_file(self, download_source, impl_hint=None):
		"""Fetch a single file. You should normally call L{download_impl}
		instead, since it handles other kinds of retrieval method too.
		It is the caller's responsibility to ensure that the returned stream is closed.
		@type download_source: L{zeroinstall.injector.model.FileSource}
		@type impl_hint: L{zeroinstall.injector.model.ZeroInstallImplementation} | None
		@rtype: tuple"""
		if self.config.handler.dry_run:
			print(_("[dry-run] downloading file {url}").format(url = download_source.url))

		if '://' not in download_source.url:
			return self._download_local_file(download_source, impl_hint)

		dl = self.download_url(download_source.url, hint = impl_hint)
		dl.expected_size = download_source.size
		return (dl.downloaded, dl.tempfile)

	# (force is deprecated and ignored)
	def download_icon(self, interface, force = False):
		"""Download an icon for this interface and add it to the
		icon cache. If the interface has no icon do nothing.
		@type interface: L{zeroinstall.injector.model.Interface}
		@type force: bool
		@return: the task doing the import, or None
		@rtype: L{tasks.Task}"""
		logger.debug("download_icon %(interface)s", {'interface': interface})

		modification_time = None
		existing_icon = self.config.iface_cache.get_icon_path(interface)
		if existing_icon:
			file_mtime = os.stat(existing_icon).st_mtime
			from email.utils import formatdate
			modification_time = formatdate(timeval = file_mtime, localtime = False, usegmt = True)

		feed = self.config.iface_cache.get_feed(interface.uri)
		if feed is None:
			return None

		# Find a suitable icon to download
		for icon in feed.get_metadata(XMLNS_IFACE, 'icon'):
			type = icon.getAttribute('type')
			if type != 'image/png':
				logger.debug(_('Skipping non-PNG icon'))
				continue
			source = icon.getAttribute('href')
			if source:
				break
			logger.warning(_('Missing "href" attribute on <icon> in %s'), interface)
		else:
			logger.info(_('No PNG icons found in %s'), interface)
			return

		dl = self.download_url(source, hint = interface, modification_time = modification_time)

		@tasks.async
		def download_and_add_icon():
			stream = dl.tempfile
			try:
				yield dl.downloaded
				tasks.check(dl.downloaded)
				if dl.unmodified: return
				stream.seek(0)

				import shutil, tempfile
				icons_cache = basedir.save_cache_path(config_site, 'interface_icons')

				tmp_file = tempfile.NamedTemporaryFile(dir = icons_cache, delete = False)
				shutil.copyfileobj(stream, tmp_file)
				tmp_file.close()

				icon_file = os.path.join(icons_cache, escape(interface.uri))
				portable_rename(tmp_file.name, icon_file)
			finally:
				stream.close()

		return download_and_add_icon()

	def download_impls(self, implementations, stores):
		"""Download the given implementations, choosing a suitable retrieval method for each.
		If any of the retrieval methods are DistributionSources and
		need confirmation, handler.confirm is called to check that the
		installation should proceed.
		@type implementations: [L{zeroinstall.injector.model.ZeroInstallImplementation}]
		@type stores: L{zeroinstall.zerostore.Stores}
		@rtype: L{zeroinstall.support.tasks.Blocker}"""
		if self.external_fetcher:
			self._download_with_external_fetcher(implementations)
			return None

		unsafe_impls = []

		to_download = []
		for impl in implementations:
			logger.debug(_("start_downloading_impls: for %(feed)s get %(implementation)s"), {'feed': impl.feed, 'implementation': impl})
			source = self.get_best_source(impl)
			if not source:
				raise SafeException(_("Implementation %(implementation_id)s of interface %(interface)s"
					" cannot be downloaded (no download locations given in "
					"interface!)") % {'implementation_id': impl.id, 'interface': impl.feed.get_name()})
			to_download.append((impl, source))

			if isinstance(source, DistributionSource) and source.needs_confirmation:
				unsafe_impls.append(source.package_id)

		@tasks.async
		def download_impls():
			if unsafe_impls:
				confirm = self.handler.confirm_install(_('The following components need to be installed using native packages. '
					'These come from your distribution, and should therefore be trustworthy, but they also '
					'run with extra privileges. In particular, installing them may run extra services on your '
					'computer or affect other users. You may be asked to enter a password to confirm. The '
					'packages are:\n\n') + ('\n'.join('- ' + x for x in unsafe_impls)))
				yield confirm
				tasks.check(confirm)

			blockers = []

			for impl, source in to_download:
				blockers.append(self.download_impl(impl, source, stores))

			# Record the first error log the rest
			error = []
			def dl_error(ex, tb = None):
				if error:
					self.handler.report_error(ex)
				else:
					error.append((ex, tb))
			while blockers:
				yield blockers
				tasks.check(blockers, dl_error)

				blockers = [b for b in blockers if not b.happened]
			if error:
				from zeroinstall import support
				support.raise_with_traceback(*error[0])

		if not to_download:
			return None

		return download_impls()

	def _download_with_external_fetcher(self, implementations):
		"""@type implementations: [L{zeroinstall.injector.model.ZeroInstallImplementation}]"""
		# Serialize implementation list to XML
		from xml.dom import minidom, XMLNS_NAMESPACE
		from zeroinstall.injector.namespaces import XMLNS_IFACE
		from zeroinstall.injector.qdom import Prefixes
		doc = minidom.getDOMImplementation().createDocument(XMLNS_IFACE, "interface", None)
		root = doc.documentElement
		root.setAttributeNS(XMLNS_NAMESPACE, 'xmlns', XMLNS_IFACE)
		for impl in implementations:
			root.appendChild(impl._toxml(doc, Prefixes(XMLNS_IFACE)))

		# Pipe XML into external process
		import subprocess
		process = subprocess.Popen(self.external_fetcher, stdin=subprocess.PIPE)
		process.communicate(doc.toxml() + "\n")

		if process.returncode != 0:
			raise SafeException(_("Download with external fetcher failed"))

	def get_best_source(self, impl):
		"""Return the best download source for this implementation.
		@type impl: L{zeroinstall.injector.model.ZeroInstallImplementation}
		@rtype: L{model.RetrievalMethod}"""
		if impl.download_sources:
			return impl.download_sources[0]
		return None

	def download_url(self, url, hint = None, modification_time = None, expected_size = None, mirror_url = None, timeout = None, auto_delete = True):
		"""The most low-level method here; just download a raw URL.
		It is the caller's responsibility to ensure that dl.stream is closed.
		@param url: the location to download from
		@type url: str
		@param hint: user-defined data to store on the Download (e.g. used by the GUI)
		@param modification_time: don't download unless newer than this
		@param mirror_url: an altertive URL to try if this one fails
		@type mirror_url: str
		@param timeout: create a blocker which triggers if a download hangs for this long
		@type timeout: float | str | None
		@rtype: L{download.Download}
		@since: 1.5"""
		if not (url.startswith('http:') or url.startswith('https:') or url.startswith('ftp:')):
			raise SafeException(_("Unknown scheme in download URL '%s'") % url)
		if self.external_store: auto_delete = False
		dl = download.Download(url, hint = hint, modification_time = modification_time, expected_size = expected_size, auto_delete = auto_delete)
		dl.mirror = mirror_url
		self.handler.monitor_download(dl)

		if isinstance(timeout, int):
			dl.timeout = tasks.Blocker('Download timeout')

		dl.downloaded = self.scheduler.download(dl, timeout = timeout)

		return dl

class StepRunner(object):
	"""The base class of all step runners.
	@since: 1.10"""

	def __init__(self, stepdata, impl_hint, may_use_mirror = True):
		"""@type stepdata: L{zeroinstall.injector.model.RetrievalMethod}
		@type may_use_mirror: bool"""
		self.stepdata = stepdata
		self.impl_hint = impl_hint
		self.may_use_mirror = may_use_mirror

	def prepare(self, fetcher, blockers):
		"""@type fetcher: L{Fetcher}
		@type blockers: [L{zeroinstall.support.tasks.Blocker}]"""
		pass

	@classmethod
	def class_for(cls, model):
		"""@type model: L{zeroinstall.injector.model.RetrievalMethod}"""
		for subcls in cls.__subclasses__():
			if subcls.model_type == type(model):
				return subcls
		raise Exception(_("Unknown download type for '%s'") % model)
	
	def close(self):
		"""Release any resources (called on success or failure)."""
		pass

class RenameStepRunner(StepRunner):
	"""A step runner for the <rename> step.
	@since: 1.10"""

	model_type = model.RenameStep

	def apply(self, basedir):
		"""@type basedir: str"""
		source = native_path_within_base(basedir, self.stepdata.source)
		dest = native_path_within_base(basedir, self.stepdata.dest)
		_ensure_dir_exists(os.path.dirname(dest))
		try:
			os.rename(source, dest)
		except OSError:
			if not os.path.exists(source):
				# Python by default reports the path of the destination in this case
				raise SafeException("<rename> source '{source}' does not exist".format(
					source = self.stepdata.source))
			raise

class RemoveStepRunner(StepRunner):
	"""A step runner for the <remove> step."""

	model_type = model.RemoveStep

	def apply(self, basedir):
		"""@type basedir: str"""
		path = native_path_within_base(basedir, self.stepdata.path)
		support.ro_rmtree(path)

class DownloadStepRunner(StepRunner):
	"""A step runner for the <archive> step.
	@since: 1.10"""

	model_type = model.DownloadSource

	def prepare(self, fetcher, blockers):
		"""@type fetcher: L{Fetcher}
		@type blockers: [L{zeroinstall.support.tasks.Blocker}]"""
		self.blocker, self.stream = fetcher.download_archive(self.stepdata, impl_hint = self.impl_hint, may_use_mirror = self.may_use_mirror)
		assert self.stream
		if self.blocker:
			blockers.append(self.blocker)
	
	def apply(self, basedir):
		"""@type basedir: str"""
		from zeroinstall.zerostore import unpack
		assert self.blocker is None or self.blocker.happened
		if self.stepdata.dest is not None:
			basedir = native_path_within_base(basedir, self.stepdata.dest)
			_ensure_dir_exists(basedir)
		unpack.unpack_archive_over(self.stepdata.url, self.stream, basedir,
				extract = self.stepdata.extract,
				type=self.stepdata.type,
				start_offset = self.stepdata.start_offset or 0)
	
	def close(self):
		self.stream.close()

class FileStepRunner(StepRunner):
	"""A step runner for the <file> step."""

	model_type = model.FileSource

	def prepare(self, fetcher, blockers):
		"""@type fetcher: L{Fetcher}
		@type blockers: [L{zeroinstall.support.tasks.Blocker}]"""
		self.blocker, self.stream = fetcher.download_file(self.stepdata,
				impl_hint = self.impl_hint)
		assert self.stream
		if self.blocker:
			blockers.append(self.blocker)

	def apply(self, basedir):
		"""@type basedir: str"""
		import shutil
		assert self.blocker is None or self.blocker.happened
		dest = native_path_within_base(basedir, self.stepdata.dest)
		_ensure_dir_exists(os.path.dirname(dest))

		self.stream.seek(0)

		with open(dest, 'wb') as output:
			shutil.copyfileobj(self.stream, output)
		os.utime(dest, (0, 0))

	def close(self):
		self.stream.close()

def native_path_within_base(base, crossplatform_path):
	"""Takes a cross-platform relative path (i.e using forward slashes, even on windows)
	and returns the absolute, platform-native version of the path.
	If the path does not resolve to a location within `base`, a SafeError is raised.
	@type base: str
	@type crossplatform_path: str
	@rtype: str
	@since: 1.10"""
	assert os.path.isabs(base)
	if crossplatform_path.startswith("/"):
		raise SafeException("path %r is not within the base directory" % (crossplatform_path,))
	native_path = os.path.join(*crossplatform_path.split("/"))
	fullpath = os.path.realpath(os.path.join(base, native_path))
	base = os.path.realpath(base)
	if not fullpath.startswith(base + os.path.sep):
		raise SafeException("path %r is not within the base directory" % (crossplatform_path,))
	return fullpath

def _ensure_dir_exists(dest):
	"""@type dest: str"""
	if not os.path.isdir(dest):
		os.makedirs(dest)
