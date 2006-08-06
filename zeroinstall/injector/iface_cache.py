# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

"""The interface cache stores downloaded and verified interfaces in ~/.cache/0install.net/interfaces (by default).
There are methods to query the cache, add to it, check signatures, etc."""

# Note:
#
# We need to know the modification time of each interface, because we refuse
# to update to an older version (this prevents an attack where the attacker
# sends back an old version which is correctly signed but has a known bug).
#
# The way we store this is a bit complicated due to backward compatibility:
#
# - GPG-signed interfaces have their signatures removed and a last-modified
#   attribute is stored containing the date from the signature.
#
# - XML-signed interfaces are stored unmodified with their signatures. The
#   date is extracted from the signature when needed.
#
# - Older versions used to add the last-modified attribute even to files
#   with XML signatures - these files therefore have invalid signatures and
#   we extract from the attribute for these.
#
# Eventually, support for the first and third cases will be removed.

import os, sys, time
from logging import debug, info, warn
from cStringIO import StringIO

from zeroinstall.injector import reader, basedir
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
		try:
			data, sigs = gpg.check_stream(signed_data)
		except:
			signed_data.seek(0)
			info("Failed to check GPG signature. Data received was:\n" + `signed_data.read()`)
			raise

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
		updated = self._oldest_trusted(sigs)
		if updated is None: return False	# None are trusted

		self.update_interface_from_network(interface, xml, updated)
		return True

	def download_key(self, interface, key_id):
		assert interface
		assert key_id
		import urlparse, urllib2, shutil, tempfile
		key_url = urlparse.urljoin(interface.uri, '%s.gpg' % key_id)
		info("Fetching key from %s", key_url)
		try:
			stream = urllib2.urlopen(key_url)
			# Python2.4: can't call fileno() on stream, so save to tmp file instead
			tmpfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-')
			shutil.copyfileobj(stream, tmpfile)
			tmpfile.flush()
			stream.close()
		except Exception, ex:
			raise SafeException("Failed to download key from '%s': %s" % (key_url, str(ex)))

		import gpg

		tmpfile.seek(0)
		gpg.import_key(tmpfile)
		tmpfile.close()

	def update_interface_from_network(self, interface, new_xml, modified_time):
		"""xml is the new XML (after the signature has been checked and
		removed). modified_time will be set as an attribute on the root."""
		debug("Updating '%s' from network; modified at %s" %
			(interface.name or interface.uri, _pretty_time(modified_time)))

		if '\n<!-- Base64 Signature' not in new_xml:
			# Only do this for old-style interfaces without
			# signatures Otherwise, we can get the time from the
			# signature, and adding this attribute just makes the
			# signature invalid.
			from xml.dom import minidom
			doc = minidom.parseString(new_xml)
			doc.documentElement.setAttribute('last-modified', str(modified_time))
			new_xml = StringIO()
			doc.writexml(new_xml)
			new_xml = new_xml.getvalue()

		self.import_new_interface(interface, new_xml, modified_time)

		import writer
		interface.last_checked = long(time.time())
		writer.save_interface(interface)

		info("Updated interface cache entry for %s (modified %s)",
			interface.get_name(), _pretty_time(modified_time))

		for w in self.watchers:
			w.interface_changed(interface)
	
	def import_new_interface(self, interface, new_xml, modified_time):
		assert modified_time

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
		os.utime(cached + '.new', (modified_time, modified_time))
		new_mtime = reader.check_readable(interface.uri, cached + '.new')
		assert new_mtime == modified_time

		old_modified = self._get_signature_date(interface.uri)
		if old_modified is None:
			old_modified = interface.last_modified

		if old_modified:
			if new_mtime < old_modified:
				raise SafeException("New interface's modification time is before old "
						    "version!"
						    "\nOld time: " + _pretty_time(old_modified) +
						    "\nNew time: " + _pretty_time(new_mtime) + 
						    "\nRefusing update (leaving new copy as " +
						    cached + ".new)")
			if new_mtime == old_modified:
				raise SafeException("Interface has changed, but modification time "
						    "hasn't! Refusing update.")
		os.rename(cached + '.new', cached)
		debug("Saved as " + cached)

		reader.update_from_cache(interface)

	def get_interface(self, uri):
		"""Get the interface for uri, creating a new one if required.
		New interfaces are initialised from the disk cache, but not from
		the network."""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri in self._interfaces:
			return self._interfaces[uri]

		debug("Initialising new interface object for %s", uri)
		self._interfaces[uri] = Interface(uri)
		reader.update_from_cache(self._interfaces[uri])
		return self._interfaces[uri]

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
		self.stores.add_archive_to_cache(required_digest, data, source.url, source.extract,
						 type = source.type, start_offset = source.start_offset or 0)
	
	def get_icon_path(self, iface):
		"Get the path of the cached icon for this interface, or None if not cached."
		return basedir.load_first_cache(config_site, 'interface_icons',
						 escape(iface.uri))
	
	def _get_signature_date(self, uri):
		"""Read the date-stamp from the signature of the cached interface.
		If the date-stamp is unavailable, returns None."""
		import gpg
		old_iface = basedir.load_first_cache(config_site, 'interfaces', escape(uri))
		if old_iface is None:
			return None
		try:
			sigs = gpg.check_stream(file(old_iface))[1]
		except SafeException, ex:
			debug("No signatures (old-style interface): %s" % ex)
			return None
		return self._oldest_trusted(sigs)
	
	def _oldest_trusted(self, sigs):
		"""Return the date of the oldest trusted signature in the list, or None if there
		are no trusted sigs in the list."""
		trusted = [s.get_timestamp() for s in sigs if s.is_trusted()]
		if trusted:
			return min(trusted)
		return None

iface_cache = IfaceCache()
