# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os
from logging import debug, info

from zeroinstall.injector import model, policy, run, handler
from zeroinstall import NeedDownload

class AutoPolicy(policy.Policy):
	__slots__ = ['allow_downloads', 'download_only', 'dry_run']

	def __init__(self, interface_uri, download_only = False, dry_run = False):
		policy.Policy.__init__(self, interface_uri, handler.Handler())
		self.dry_run = dry_run
		self.allow_downloads = not dry_run
		self.download_only = download_only
		self.dry_run = dry_run

	def need_download(self):
		"""Decide whether we need to download anything (but don't do it!)"""
		old = self.allow_downloads
		self.allow_downloads = False
		try:
			try:
				self.recalculate()
				debug("Recalculated: ready = %s", self.ready)
				if not self.ready: return False
				self.start_downloading_impls()
			except NeedDownload:
				return True
			return False
		finally:
			self.allow_downloads = old
	
	def begin_iface_download(self, interface, force = False):
		if self.dry_run or not self.allow_downloads:
			raise NeedDownload(interface.uri)
		else:
			policy.Policy.begin_iface_download(self, interface, force)

	def start_downloading_impls(self):
		for iface, impl in self.get_uncached_implementations():
			debug("start_downloading_impls: for %s get %s", iface, impl)
			if not impl.download_sources:
				raise model.SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!)")
			source = impl.download_sources[0]
			if self.dry_run or not self.allow_downloads:
				raise NeedDownload(source.url)
			else:
				from zeroinstall.injector import download
				dl = download.begin_impl_download(source)
				self.handler.monitor_download(dl)

	def execute(self, prog_args, main = None):
		self.start_downloading_impls()
		self.handler.wait_for_downloads()
		if not self.download_only:
			run.execute(self, prog_args, dry_run = self.dry_run, main = main)
		else:
			info("Downloads done (download-only mode)")
	
	def recalculate_with_dl(self):
		self.recalculate()
		if self.handler.monitored_downloads:
			self.handler.wait_for_downloads()
			self.recalculate()
	
	def download_and_execute(self, prog_args, refresh = False, main = None):
		self.recalculate_with_dl()
		if refresh:
			self.refresh_all(False)
			self.recalculate_with_dl()
		if not self.ready:
			raise model.SafeException("Can't find all required implementations:\n" +
				'\n'.join(["- %s -> %s" % (iface, self.implementation[iface])
					   for iface  in self.implementation]))
		self.execute(prog_args, main = main)
