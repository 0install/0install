import os, sys
from optparse import OptionParser

from zeroinstall.injector import model, download
from zeroinstall.injector import policy, run

class AutoPolicy(policy.Policy):
	monitored_downloads = None

	def __init__(self, interface_uri):
		policy.Policy.__init__(self, interface_uri)
		self.monitored_downloads = []

	def monitor_download(self, dl):
		error_stream = dl.start()
		self.monitored_downloads.append((error_stream, dl))

	def start_downloading_impls(self):
		for iface, impl in self.get_uncached_implementations():
			if not impl.download_sources:
				raise model.SafeException("Implementation " + impl.id + " of "
					"interface " + iface.get_name() + " cannot be "
					"downloaded (no download locations given in "
					"interface!")
			dl = download.begin_impl_download(impl.download_sources[0])
			self.monitor_download(dl)

	def wait_for_downloads(self):
		while self.monitored_downloads:
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
		run.execute(self, prog_args)
