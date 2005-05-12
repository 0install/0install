import os, sys
from optparse import OptionParser

from zeroinstall.injector import model, download
from zeroinstall.injector import policy, run

class NeedDownload(Exception):
	"""Thrown if we tried to start a download with allow_downloads = False"""
	def __init__(self, url):
		Exception.__init__(self, "Would download '%s'" % url)

class AutoPolicy(policy.Policy):
	monitored_downloads = None
	verbose = None
	allow_downloads = False
	download_only = False
	dry_run = False

	def __init__(self, interface_uri, quiet,
			verbose = False, download_only = False,
			dry_run = False):
		if not interface_uri.startswith('http:'):
			interface_uri = os.path.realpath(interface_uri)	# For testing
		policy.Policy.__init__(self, interface_uri)
		self.dry_run = dry_run
		self.quiet = quiet
		self.allow_downloads = not dry_run
		self.monitored_downloads = []
		self.verbose = verbose
		self.download_only = download_only
		self.dry_run = dry_run
	
	def need_download(self):
		"""Decide whether we need to download anything (but don't do it!)"""
		old = self.allow_downloads
		self.allow_downloads = False
		try:
			try:
				self.recalculate()
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

	def monitor_download(self, dl):
		assert self.allow_downloads
		error_stream = dl.start()
		self.monitored_downloads.append((error_stream, dl))

	def start_downloading_impls(self):
		for iface, impl in self.get_uncached_implementations():
			if not impl.download_sources:
				raise model.SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!")
			source = impl.download_sources[0]
			if self.dry_run or not self.allow_downloads:
				raise NeedDownload(source.url)
			else:
				dl = download.begin_impl_download(source)
				self.monitor_download(dl)

	def wait_for_downloads(self):
		while self.monitored_downloads:
			if not self.quiet:
				print "Currently downloading:"
				for e, dl in self.monitored_downloads:
					print "- " + dl.url

			for e, dl in self.monitored_downloads[:]:
				errors =  e.read()
				if errors:
					dl.error_stream_data(errors)
					continue
				e.close()
				self.monitored_downloads.remove((e, dl))
				data = dl.error_stream_closed()
				if isinstance(dl, download.InterfaceDownload):
					self.check_signed_data(dl, data)
				elif isinstance(dl, download.ImplementationDownload):
					self.add_to_cache(dl.source, data)
				else:
					raise Exception("Unknown download type %s" % dl)

	def execute(self, prog_args):
		self.start_downloading_impls()
		self.wait_for_downloads()
		if not self.download_only:
			run.execute(self, prog_args, verbose = self.verbose,
				    dry_run = self.dry_run)
		elif self.verbose:
			print "Downloads done (download-only mode)"
	
	def recalculate_with_dl(self):
		self.recalculate()
		if self.monitored_downloads:
			self.wait_for_downloads()
			self.recalculate()
	
	def download_and_execute(self, prog_args):
		self.recalculate_with_dl()
		if options.refresh:
			self.refresh_all(False)
			self.recalculate_with_dl()
		if not self.ready:
			raise model.SafeException("Can't find all required implementations:\n" +
				'\n'.join(["- %s -> %s" % (iface, impl)
					   for iface, impl in self.walk_implementations()]))
		self.execute(prog_args)
