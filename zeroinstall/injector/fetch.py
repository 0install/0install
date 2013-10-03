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
