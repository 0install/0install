"""
Manages the feed cache.

@var iface_cache: A singleton cache object. You should normally use this rather than
creating new cache objects.

"""
# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

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

from zeroinstall import _
from zeroinstall.support import basedir
from zeroinstall.injector import reader, model
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.injector.model import Interface, escape, unescape
from zeroinstall import zerostore, SafeException

def _pretty_time(t):
	assert isinstance(t, (int, long)), t
	return time.strftime('%Y-%m-%d %H:%M:%S UTC', time.localtime(t))

class ReplayAttack(SafeException):
	"""Attempt to import a feed that's older than the one in the cache."""
	pass

class PendingFeed(object):
	"""A feed that has been downloaded but not yet added to the interface cache.
	Feeds remain in this state until the user confirms that they trust at least
	one of the signatures.
	@ivar url: URL for the feed
	@type url: str
	@ivar signed_data: the untrusted data
	@type signed_data: stream
	@ivar sigs: signatures extracted from signed_data
	@type sigs: [L{gpg.Signature}]
	@ivar new_xml: the payload of the signed_data, or the whole thing if XML
	@type new_xml: str
	@since: 0.25"""
	__slots__ = ['url', 'signed_data', 'sigs', 'new_xml']

	def __init__(self, url, signed_data):
		"""Downloaded data is a GPG-signed message.
		@param url: the URL of the downloaded feed
		@type url: str
		@param signed_data: the downloaded data (not yet trusted)
		@type signed_data: stream
		@raise SafeException: if the data is not signed, and logs the actual data"""
		self.url = url
		self.signed_data = signed_data
		self.recheck()

	def download_keys(self, handler, feed_hint = None, key_mirror = None):
		"""Download any required GPG keys not already on our keyring.
		When all downloads are done (successful or otherwise), add any new keys
		to the keyring, L{recheck}.
		@param handler: handler to manage the download
		@type handler: L{handler.Handler}
		@param key_mirror: URL of directory containing keys, or None to use feed's directory
		@type key_mirror: str
		"""
		downloads = {}
		blockers = []
		for x in self.sigs:
			key_id = x.need_key()
			if key_id:
				import urlparse
				key_url = urlparse.urljoin(key_mirror or self.url, '%s.gpg' % key_id)
				info(_("Fetching key from %s"), key_url)
				dl = handler.get_download(key_url, hint = feed_hint)
				downloads[dl.downloaded] = (dl, dl.tempfile)
				blockers.append(dl.downloaded)

		exception = None
		any_success = False

		from zeroinstall.support import tasks

		while blockers:
			yield blockers

			old_blockers = blockers
			blockers = []

			for b in old_blockers:
				try:
					tasks.check(b)
					if b.happened:
						dl, stream = downloads[b]
						stream.seek(0)
						self._downloaded_key(stream)
						any_success = True
					else:
						blockers.append(b)
				except Exception:
					_type, exception, tb = sys.exc_info()
					warn(_("Failed to import key for '%(url)s': %(exception)s"), {'url': self.url, 'exception': str(exception)})

		if exception and not any_success:
			raise exception, None, tb

		self.recheck()

	def _downloaded_key(self, stream):
		import shutil, tempfile
		from zeroinstall.injector import gpg

		info(_("Importing key for feed '%s'"), self.url)

		# Python2.4: can't call fileno() on stream, so save to tmp file instead
		tmpfile = tempfile.TemporaryFile(prefix = 'injector-dl-data-')
		try:
			shutil.copyfileobj(stream, tmpfile)
			tmpfile.flush()

			tmpfile.seek(0)
			gpg.import_key(tmpfile)
		finally:
			tmpfile.close()

	def recheck(self):
		"""Set new_xml and sigs by reading signed_data.
		You need to call this when previously-missing keys are added to the GPG keyring."""
		import gpg
		try:
			self.signed_data.seek(0)
			stream, sigs = gpg.check_stream(self.signed_data)
			assert sigs

			data = stream.read()
			if stream is not self.signed_data:
				stream.close()

			self.new_xml = data
			self.sigs = sigs
		except:
			self.signed_data.seek(0)
			info(_("Failed to check GPG signature. Data received was:\n") + repr(self.signed_data.read()))
			raise

class IfaceCache(object):
	"""
	The interface cache stores downloaded and verified interfaces in
	~/.cache/0install.net/interfaces (by default).

	There are methods to query the cache, add to it, check signatures, etc.

	The cache is updated by L{fetch.Fetcher}.

	Confusingly, this class is really two caches combined: the in-memory
	cache of L{model.Interface} objects, and an on-disk cache of L{model.ZeroInstallFeed}s.
	It will probably be split into two in future.

	@ivar distro: the native distribution proxy
	@type distro: L{distro.Distribution}

	@see: L{iface_cache} - the singleton IfaceCache instance.
	"""

	__slots__ = ['_interfaces', '_feeds', '_distro', '_config']

	def __init__(self, distro = None):
		"""@param distro: distribution used to fetch "distribution:" feeds (since 0.49)
		@param distro: distribution used to resolve "distribution:" feeds
		@type distro: L{distro.Distribution}, or None to use the host distribution
		"""
		self._interfaces = {}
		self._feeds = {}
		self._distro = distro

	@property
	def stores(self):
		"""deprecated"""
		from zeroinstall.injector import policy
		raise Exception("iface_cache.stores")
		return policy.get_deprecated_singleton_config().stores

	@property
	def distro(self):
		if self._distro is None:
			from zeroinstall.injector.distro import get_host_distribution
			self._distro = get_host_distribution()
		return self._distro

	def update_interface_if_trusted(self, interface, sigs, xml):
		import warnings
		warnings.warn("Use update_feed_if_trusted instead", DeprecationWarning, stacklevel = 2)
		return self.update_feed_if_trusted(interface.uri, sigs, xml)

	def update_feed_if_trusted(self, feed_url, sigs, xml):
		"""Update a cached feed (using L{update_feed_from_network})
		if we trust the signatures.
		If we don't trust any of the signatures, do nothing.
		@param feed_url: the feed being updated
		@type feed_url: str
		@param sigs: signatures from L{gpg.check_stream}
		@type sigs: [L{gpg.Signature}]
		@param xml: the downloaded replacement feed document
		@type xml: str
		@return: True if the feed was updated
		@rtype: bool
		@since: 0.48
		"""
		import trust
		updated = self._oldest_trusted(sigs, trust.domain_from_url(feed_url))
		if updated is None: return False	# None are trusted

		self.update_feed_from_network(feed_url, xml, updated)
		return True

	def update_interface_from_network(self, interface, new_xml, modified_time):
		import warnings
		warnings.warn("Use update_feed_from_network instead", DeprecationWarning, stacklevel = 2)
		self.update_feed_from_network(interface.uri, new_xml, modified_time)

	def update_feed_from_network(self, feed_url, new_xml, modified_time):
		"""Update a cached feed.
		Called by L{update_feed_if_trusted} if we trust this data.
		After a successful update, L{writer} is used to update the feed's
		last_checked time.
		@param feed_url: the feed being updated
		@type feed_url: L{model.Interface}
		@param new_xml: the downloaded replacement feed document
		@type new_xml: str
		@param modified_time: the timestamp of the oldest trusted signature
		(used as an approximation to the feed's modification time)
		@type modified_time: long
		@raises ReplayAttack: if modified_time is older than the currently cached time
		@since: 0.48
		"""
		debug(_("Updating '%(interface)s' from network; modified at %(time)s") %
			{'interface': feed_url, 'time': _pretty_time(modified_time)})

		if '\n<!-- Base64 Signature' not in new_xml:
			# Only do this for old-style feeds without
			# signatures Otherwise, we can get the time from the
			# signature, and adding this attribute just makes the
			# signature invalid.
			from xml.dom import minidom
			doc = minidom.parseString(new_xml)
			doc.documentElement.setAttribute('last-modified', str(modified_time))
			new_xml = StringIO()
			doc.writexml(new_xml)
			new_xml = new_xml.getvalue()

		self._import_new_feed(feed_url, new_xml, modified_time)

		feed = self.get_feed(feed_url)

		import writer
		feed.last_checked = long(time.time())
		writer.save_feed(feed)

		info(_("Updated feed cache entry for %(interface)s (modified %(time)s)"),
			{'interface': feed.get_name(), 'time': _pretty_time(modified_time)})

	def _import_new_feed(self, feed_url, new_xml, modified_time):
		"""Write new_xml into the cache.
		@param feed_url: the URL for the feed being updated
		@param new_xml: the data to write
		@param modified_time: when new_xml was modified
		@raises ReplayAttack: if the new mtime is older than the current one
		"""
		assert modified_time

		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, escape(feed_url))

		old_modified = None
		if os.path.exists(cached):
			old_xml = file(cached).read()
			if old_xml == new_xml:
				debug(_("No change"))
				# Update in-memory copy, in case someone else updated the disk copy
				self.get_feed(feed_url, force = True)
				return
			old_modified = int(os.stat(cached).st_mtime)

		# Do we need to write this temporary file now?
		stream = file(cached + '.new', 'w')
		stream.write(new_xml)
		stream.close()
		os.utime(cached + '.new', (modified_time, modified_time))
		new_mtime = reader.check_readable(feed_url, cached + '.new')
		assert new_mtime == modified_time

		old_modified = self._get_signature_date(feed_url) or old_modified

		if old_modified:
			if new_mtime < old_modified:
				os.unlink(cached + '.new')
				raise ReplayAttack(_("New feed's modification time is "
					"before old version!\nInterface: %(iface)s\nOld time: %(old_time)s\nNew time: %(new_time)s\n"
					"Refusing update.")
					% {'iface': feed_url, 'old_time': _pretty_time(old_modified), 'new_time': _pretty_time(new_mtime)})
			if new_mtime == old_modified:
				# You used to have to update the modification time manually.
				# Now it comes from the signature, this check isn't useful
				# and often causes problems when the stored format changes
				# (e.g., when we stopped writing last-modified attributes)
				pass
				#raise SafeException("Interface has changed, but modification time "
				#		    "hasn't! Refusing update.")
		os.rename(cached + '.new', cached)
		debug(_("Saved as %s") % cached)

		self.get_feed(feed_url, force = True)

	def get_feed(self, url, force = False, selections_ok = False):
		"""Get a feed from the cache.
		@param url: the URL of the feed
		@param force: load the file from disk again
		@param selections_ok: if url is a local selections file, return that instead
		@return: the feed, or None if it isn't cached
		@rtype: L{model.ZeroInstallFeed}"""
		if not force:
			feed = self._feeds.get(url, False)
			if feed != False:
				return feed

		if url.startswith('distribution:'):
			master_feed = self.get_feed(url.split(':', 1)[1])
			if not master_feed:
				return None	# Can't happen?
			feed = self.distro.get_feed(master_feed)
		else:
			feed = reader.load_feed_from_cache(url, selections_ok = selections_ok)
			if selections_ok and feed and not isinstance(feed, model.ZeroInstallFeed):
				assert feed.selections is not None
				return feed	# (it's actually a selections document)
		if feed:
			reader.update_user_feed_overrides(feed)
		self._feeds[url] = feed
		return feed

	def get_interface(self, uri):
		"""Get the interface for uri, creating a new one if required.
		New interfaces are initialised from the disk cache, but not from
		the network.
		@param uri: the URI of the interface to find
		@rtype: L{model.Interface}
		"""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri in self._interfaces:
			return self._interfaces[uri]

		debug(_("Initialising new interface object for %s"), uri)
		self._interfaces[uri] = Interface(uri)
		reader.update_from_cache(self._interfaces[uri])
		return self._interfaces[uri]

	def list_all_interfaces(self):
		"""List all interfaces in the cache.
		@rtype: [str]
		"""
		all = set()
		for d in basedir.load_cache_paths(config_site, 'interfaces'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all.add(unescape(leaf))
		for d in basedir.load_config_paths(config_site, config_prog, 'user_overrides'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all.add(unescape(leaf))
		return list(all)	# Why not just return the set?

	def get_icon_path(self, iface):
		"""Get the path of a cached icon for an interface.
		@param iface: interface whose icon we want
		@return: the path of the cached icon, or None if not cached.
		@rtype: str"""
		return basedir.load_first_cache(config_site, 'interface_icons',
						 escape(iface.uri))

	def get_cached_signatures(self, uri):
		"""Verify the cached interface using GPG.
		Only new-style XML-signed interfaces retain their signatures in the cache.
		@param uri: the feed to check
		@type uri: str
		@return: a list of signatures, or None
		@rtype: [L{gpg.Signature}] or None
		@since: 0.25"""
		import gpg
		if os.path.isabs(uri):
			old_iface = uri
		else:
			old_iface = basedir.load_first_cache(config_site, 'interfaces', escape(uri))
			if old_iface is None:
				return None
		try:
			return gpg.check_stream(file(old_iface))[1]
		except SafeException, ex:
			debug(_("No signatures (old-style interface): %s") % ex)
			return None

	def _get_signature_date(self, uri):
		"""Read the date-stamp from the signature of the cached interface.
		If the date-stamp is unavailable, returns None."""
		import trust
		sigs = self.get_cached_signatures(uri)
		if sigs:
			return self._oldest_trusted(sigs, trust.domain_from_url(uri))

	def _oldest_trusted(self, sigs, domain):
		"""Return the date of the oldest trusted signature in the list, or None if there
		are no trusted sigs in the list."""
		trusted = [s.get_timestamp() for s in sigs if s.is_trusted(domain)]
		if trusted:
			return min(trusted)
		return None

	def mark_as_checking(self, url):
		"""Touch a 'last_check_attempt_timestamp' file for this feed.
		If url is a local path, nothing happens.
		This prevents us from repeatedly trying to download a failing feed many
		times in a short period."""
		if os.path.isabs(url):
			return
		feeds_dir = basedir.save_cache_path(config_site, config_prog, 'last-check-attempt')
		timestamp_path = os.path.join(feeds_dir, model._pretty_escape(url))
		fd = os.open(timestamp_path, os.O_WRONLY | os.O_CREAT, 0644)
		os.close(fd)
		os.utime(timestamp_path, None)	# In case file already exists

	def get_last_check_attempt(self, url):
		"""Return the time of the most recent update attempt for a feed.
		@see: L{mark_as_checking}
		@return: The time, or None if none is recorded
		@rtype: float | None"""
		timestamp_path = basedir.load_first_cache(config_site, config_prog, 'last-check-attempt', model._pretty_escape(url))
		if timestamp_path:
			return os.stat(timestamp_path).st_mtime
		return None

	def get_feed_imports(self, iface):
		"""Get all feeds that add to this interface.
		This is the feeds explicitly added by the user, feeds added by the distribution,
		and feeds imported by a <feed> in the main feed (but not recursively, at present).
		@rtype: L{Feed}
		@since: 0.48"""
		main_feed = self.get_feed(iface.uri)
		if main_feed:
			return iface.extra_feeds + main_feed.feeds
		else:
			return iface.extra_feeds

	def get_feeds(self, iface):
		"""Get all feeds for this interface. This is a mapping from feed URLs
		to ZeroInstallFeeds. It includes the interface's main feed, plus the
		resolution of every feed returned by L{get_feed_imports}. Uncached
		feeds are indicated by a value of None.
		@rtype: {str: L{ZeroInstallFeed} | None}
		@since: 0.48"""
		main_feed = self.get_feed(iface.uri)
		results = {iface.uri: main_feed}
		for imp in iface.extra_feeds:
			try:
				results[imp.uri] = self.get_feed(imp.uri)
			except SafeException, ex:
				warn("Failed to load feed '%s: %s", imp.uri, ex)
		if main_feed:
			for imp in main_feed.feeds:
				results[imp.uri] = self.get_feed(imp.uri)
		return results

	def get_implementations(self, iface):
		"""Return all implementations from all of iface's feeds.
		@rtype: [L{Implementation}]
		@since: 0.48"""
		impls = []
		for feed in self.get_feeds(iface).itervalues():
			if feed:
				impls += feed.implementations.values()
		return impls

#iface_cache = IfaceCache()
