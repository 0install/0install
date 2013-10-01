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
from zeroinstall.injector.model import Recipe, SafeException, escape
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

	def _get_archive_mirror(self, url):
		"""@type source: L{model.DownloadSource}
		@rtype: str"""
		if self.config.mirror is None:
			return None
		if support.urlparse(url).hostname == 'localhost':
			return None
		if sys.version_info[0] > 2:
			from urllib.parse import quote
		else:
			from urllib import quote
		return '{mirror}/archive/{archive}'.format(
				mirror = self.config.mirror,
				archive = quote(url.replace('/', '#'), safe = ''))

	def _get_impl_mirror(self, impl):
		"""@type impl: L{zeroinstall.injector.model.ZeroInstallImplementation}
		@rtype: str"""
		return self._get_mirror_url(impl.feed.url, 'impl/' + _escape_slashes(impl.id))

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
			mirror = self._get_archive_mirror(download_source.url)
		else:
			mirror = None

		if self.config.handler.dry_run:
			print(_("[dry-run] downloading archive {url}").format(url = download_source.url))
		dl = self.download_url(download_source.url, hint = impl_hint.feed.url, mirror_url = mirror)
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

		dl = self.download_url(download_source.url, hint = impl_hint.feed.url)
		dl.expected_size = download_source.size
		return (dl.downloaded, dl.tempfile)

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
