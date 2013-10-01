"""
Downloads feeds, keys, packages and icons.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os, sys

from zeroinstall import support
from zeroinstall.support import tasks
from zeroinstall.injector.model import SafeException
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
