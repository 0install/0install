"""The interface cache stores downloaded and verified interfaces in ~/.cache/0install.net/interfaces (by default).
There are methods to query the cache, add to it, check signatures, etc."""

import os, sys, time
from logging import debug, info, warn
from cStringIO import StringIO

from zeroinstall.injector import download, reader, basedir
from zeroinstall.injector.namespaces import *
from zeroinstall.injector.model import *
from zeroinstall import zerostore

def _pretty_time(t):
	assert isinstance(t, (int, long))
	return time.strftime('%Y-%m-%d %H:%M:%S UTC', time.localtime(t))

class IfaceCache(object):
	__slots__ = ['watchers', '_interfaces', 'stores']

	def __init__(self):
		self.watchers = []
		self._interfaces = {}

		self.stores = zerostore.Stores()
	
	def add_watcher(self, w):
		assert w not in self.watchers
		self.watchers.append(w)

	def check_signed_data(self, interface, signed_data, handler):
		"""Downloaded data is a GPG-signed message. Check that the signature is trusted
		and call self.update_interface_from_network() when done.
		Calls handler.confirm_trust_keys() if keys are not trusted.
		"""
		assert isinstance(interface, Interface)
		import gpg
		data, sigs = gpg.check_stream(signed_data)

		new_keys = False
		import_error = None
		for x in sigs:
			need_key = x.need_key()
			if need_key:
				try:
					self.download_key(interface, need_key)
				except SafeException, ex:
					import_error = ex
				new_keys = True

		if new_keys:
			signed_data.seek(0)
			data, sigs = gpg.check_stream(signed_data)
			# If we got an error importing the keys, then report it now.
			# If we still have missing keys, raise it as an exception, but
			# if the keys got imported, just print and continue...
			if import_error:
				for x in sigs:
					if x.need_key():
						raise import_error
				print >>sys.stderr, str(ex)

		iface_xml = data.read()
		data.close()

		if not sigs:
			raise SafeException('No signature on %s!\n'
					    'Possible reasons:\n'
					    '- You entered the interface URL incorrectly.\n'
					    '- The server delivered an error; try viewing the URL in a web browser.\n'
					    '- The developer gave you the URL of the unsigned interface by mistake.'
					    % interface.uri)

		if not self.update_interface_if_trusted(interface, sigs, iface_xml):
			handler.confirm_trust_keys(interface, sigs, iface_xml)
	
	def update_interface_if_trusted(self, interface, sigs, xml):
		for s in sigs:
			if s.is_trusted():
				self.update_interface_from_network(interface, xml, s.get_timestamp())
				return True
		return False

	def download_key(self, interface, key_id):
		assert interface
		assert key_id
		import urlparse, urllib2
		key_url = urlparse.urljoin(interface.uri, '%s.gpg' % key_id)
		info("Fetching key from %s", key_url)
		try:
			stream = urllib2.urlopen(key_url)
		except Exception, ex:
			raise SafeException("Failed to download key from '%s': %s" % (key_url, str(ex)))
		import gpg
		gpg.import_key(stream)
		stream.close()

	def update_interface_from_network(self, interface, new_xml, modified_time):
		"""xml is the new XML (after the signature has been checked and
		removed). modified_time will be set as an attribute on the root."""
		debug("Updating '%s' from network; modified at %s" %
			(interface.name or interface.uri, _pretty_time(modified_time)))

		from xml.dom import minidom
		doc = minidom.parseString(new_xml)
		doc.documentElement.setAttribute('last-modified', str(modified_time))
		new_xml = StringIO()
		doc.writexml(new_xml)

		self.import_new_interface(interface, new_xml.getvalue())

		import writer
		interface.last_checked = long(time.time())
		writer.save_interface(interface)

		info("Updated interface cache entry for %s (modified %s)",
			interface.get_name(), _pretty_time(modified_time))

		for w in self.watchers:
			w.interface_changed(interface)
	
	def import_new_interface(self, interface, new_xml):
		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, escape(interface.uri))

		if os.path.exists(cached):
			old_xml = file(cached).read()
			if old_xml == new_xml:
				debug("No change")
				return

		stream = file(cached + '.new', 'w')
		stream.write(new_xml)
		stream.close()
		new_mtime = reader.check_readable(interface.uri, cached + '.new')
		assert new_mtime
		if interface.last_modified:
			if new_mtime < interface.last_modified:
				raise SafeException("New interface's modification time is before old "
						    "version!"
						    "\nOld time: " + _pretty_time(interface.last_modified) +
						    "\nNew time: " + _pretty_time(new_mtime) + 
						    "\nRefusing update (leaving new copy as " +
						    cached + ".new)")
			if new_mtime == interface.last_modified:
				raise SafeException("Interface has changed, but modification time "
						    "hasn't! Refusing update.")
		os.rename(cached + '.new', cached)
		debug("Saved as " + cached)

		reader.update_from_cache(interface)

	def get_interface(self, uri):
		"""Get the interface for uri. Return is (new, Interface). new is True if
		we just created the new object in memory."""
		debug("get_interface %s", uri)
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri in self._interfaces:
			return (False, self._interfaces[uri])

		debug("Initialising new interface object for %s", uri)
		self._interfaces[uri] = Interface(uri)
		cached = reader.update_from_cache(self._interfaces[uri])
		if cached:
			debug("(already in disk cache)")
			assert self._interfaces[uri].name
		else:
			debug("(unknown interface)")
		return (True, self._interfaces[uri])

	def list_all_interfaces(self):
		all = {}
		for d in basedir.load_cache_paths(config_site, 'interfaces'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all[leaf] = True
		for d in basedir.load_config_paths(config_site, config_prog, 'user_overrides'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all[leaf] = True
		return map(unescape, all.keys())

	def add_to_cache(self, source, data):
		assert isinstance(source, DownloadSource)
		required_digest = source.implementation.id
		url = source.url
		self.stores.add_archive_to_cache(required_digest, data, source.url, source.extract)

iface_cache = IfaceCache()
