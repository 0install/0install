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

from __future__ import print_function

import os, sys, time

from zeroinstall import _, logger
from zeroinstall.support import basedir, portable_rename, raise_with_traceback, unicode
from zeroinstall.injector import reader, model
from zeroinstall.injector.namespaces import config_site, config_prog
from zeroinstall.injector.model import Interface, escape, unescape
from zeroinstall import SafeException

# If we started a check within this period, don't start another one:
FAILED_CHECK_DELAY = 60 * 60	# 1 Hour

def _pretty_time(t):
	#assert isinstance(t, (int, long)), t
	"""@type t: int
	@rtype: str"""
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

	def download_keys(self, fetcher, feed_hint = None, key_mirror = None):
		"""Download any required GPG keys not already on our keyring.
		When all downloads are done (successful or otherwise), add any new keys
		to the keyring, L{recheck}.
		@param fetcher: fetcher to manage the download (was Handler before version 1.5)
		@type fetcher: L{fetch.Fetcher}
		@param key_mirror: URL of directory containing keys, or None to use feed's directory
		@type key_mirror: str
		@rtype: [L{zeroinstall.support.tasks.Blocker}]"""
		downloads = {}
		blockers = []
		for x in self.sigs:
			key_id = x.need_key()
			if key_id:
				try:
					import urlparse
				except ImportError:
					from urllib import parse as urlparse	# Python 3
				key_url = urlparse.urljoin(key_mirror or self.url, '%s.gpg' % key_id)
				logger.info(_("Fetching key from %s"), key_url)
				dl = fetcher.download_url(key_url, hint = feed_hint)
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
				dl, stream = downloads[b]
				try:
					tasks.check(b)
					if b.happened:
						stream.seek(0)
						self._downloaded_key(stream)
						any_success = True
						stream.close()
					else:
						blockers.append(b)
				except Exception:
					_type, exception, tb = sys.exc_info()
					logger.warning(_("Failed to import key for '%(url)s': %(exception)s"), {'url': self.url, 'exception': str(exception)})
					stream.close()

		if exception and not any_success:
			raise_with_traceback(exception, tb)

		self.recheck()

	def _downloaded_key(self, stream):
		"""@type stream: file"""
		import shutil, tempfile
		from zeroinstall.injector import gpg

		logger.info(_("Importing key for feed '%s'"), self.url)

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
		from . import gpg
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
			logger.info(_("Failed to check GPG signature. Data received was:\n") + repr(self.signed_data.read()))
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
		@type distro: L{distro.Distribution}, or None to use the host distribution"""
		self._interfaces = {}
		self._feeds = {}
		self._distro = distro

	@property
	def stores(self):
		from zeroinstall.injector import policy
		return policy.get_deprecated_singleton_config().stores

	@property
	def distro(self):
		if self._distro is None:
			from zeroinstall.injector.distro import get_host_distribution
			self._distro = get_host_distribution()
		return self._distro

	def update_feed_if_trusted(self, feed_url, sigs, xml, dry_run = False):
		"""Update a cached feed (using L{update_feed_from_network})
		if we trust the signatures.
		If we don't trust any of the signatures, do nothing.
		@param feed_url: the feed being updated
		@type feed_url: str
		@param sigs: signatures from L{gpg.check_stream}
		@type sigs: [L{gpg.Signature}]
		@param xml: the downloaded replacement feed document
		@type xml: str
		@type dry_run: bool
		@return: True if the feed was updated
		@rtype: bool
		@since: 0.48"""
		from . import trust
		updated = self._oldest_trusted(sigs, trust.domain_from_url(feed_url))
		if updated is None: return False	# None are trusted

		self.update_feed_from_network(feed_url, xml, updated, dry_run = dry_run)
		return True

	def update_feed_from_network(self, feed_url, new_xml, modified_time, dry_run = False):
		"""Update a cached feed.
		Called by L{update_feed_if_trusted} if we trust this data.
		After a successful update, L{writer} is used to update the feed's
		last_checked time.
		@param feed_url: the feed being updated
		@type feed_url: L{model.Interface}
		@param new_xml: the downloaded replacement feed document
		@type new_xml: str
		@param modified_time: the timestamp of the oldest trusted signature (used as an approximation to the feed's modification time)
		@type modified_time: long
		@type dry_run: bool
		@raises ReplayAttack: if modified_time is older than the currently cached time
		@since: 0.48"""
		logger.debug(_("Updating '%(interface)s' from network; modified at %(time)s") %
			{'interface': feed_url, 'time': _pretty_time(modified_time)})

		self._import_new_feed(feed_url, new_xml, modified_time, dry_run)

		if dry_run: return

		feed = self.get_feed(feed_url)

		from . import writer
		feed.last_checked = int(time.time())
		writer.save_feed(feed)

		logger.info(_("Updated feed cache entry for %(interface)s (modified %(time)s)"),
			{'interface': feed.get_name(), 'time': _pretty_time(modified_time)})

	def _import_new_feed(self, feed_url, new_xml, modified_time, dry_run):
		"""Write new_xml into the cache.
		@param feed_url: the URL for the feed being updated
		@type feed_url: str
		@param new_xml: the data to write
		@type new_xml: str
		@param modified_time: when new_xml was modified
		@type modified_time: int
		@type dry_run: bool
		@raises ReplayAttack: if the new mtime is older than the current one"""
		assert modified_time
		assert isinstance(new_xml, bytes), repr(new_xml)

		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, escape(feed_url))

		old_modified = None
		if os.path.exists(cached):
			with open(cached, 'rb') as stream:
				old_xml = stream.read()
			if old_xml == new_xml:
				logger.debug(_("No change"))
				# Update in-memory copy, in case someone else updated the disk copy
				self.get_feed(feed_url, force = True)
				return
			old_modified = int(os.stat(cached).st_mtime)

		if dry_run:
			print(_("[dry-run] would cache feed {url} as {cached}").format(
				url = feed_url,
				cached = cached))
			from io import BytesIO
			from zeroinstall.injector import qdom
			root = qdom.parse(BytesIO(new_xml), filter_for_version = True)
			feed = model.ZeroInstallFeed(root)
			reader.update_user_feed_overrides(feed)
			self._feeds[feed_url] = feed
			return

		# Do we need to write this temporary file now?
		try:
			with open(cached + '.new', 'wb') as stream:
				stream.write(new_xml)
			os.utime(cached + '.new', (modified_time, modified_time))
			new_mtime = reader.check_readable(feed_url, cached + '.new')
			assert new_mtime == modified_time

			old_modified = self._get_signature_date(feed_url) or old_modified

			if old_modified:
				if new_mtime < old_modified:
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
		except:
			os.unlink(cached + '.new')
			raise

		portable_rename(cached + '.new', cached)
		logger.debug(_("Saved as %s") % cached)

		self.get_feed(feed_url, force = True)

	def get_feed(self, url, force = False, selections_ok = False):
		"""Get a feed from the cache.
		@param url: the URL of the feed
		@type url: str
		@param force: load the file from disk again
		@type force: bool
		@param selections_ok: if url is a local selections file, return that instead
		@type selections_ok: bool
		@return: the feed, or None if it isn't cached
		@rtype: L{model.ZeroInstallFeed}"""
		if not force:
			feed = self._feeds.get(url, False)
			if feed != False:
				return feed

		if url.startswith('distribution:'):
			master_feed = self.get_feed(url.split(':', 1)[1])
			if not master_feed:
				return None	# e.g. when checking a selections document
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
		@type uri: str
		@rtype: L{model.Interface}"""
		if type(uri) == str:
			uri = unicode(uri)
		assert isinstance(uri, unicode)

		if uri in self._interfaces:
			return self._interfaces[uri]

		logger.debug(_("Initialising new interface object for %s"), uri)
		self._interfaces[uri] = Interface(uri)
		reader.update_from_cache(self._interfaces[uri], iface_cache = self)
		return self._interfaces[uri]

	def list_all_interfaces(self):
		"""List all interfaces in the cache.
		@rtype: [str]"""
		all = set()
		for d in basedir.load_cache_paths(config_site, 'interfaces'):
			for leaf in os.listdir(d):
				if not leaf.startswith('.'):
					all.add(unescape(leaf))
		return list(all)	# Why not just return the set?

	def get_icon_path(self, iface):
		"""Get the path of a cached icon for an interface.
		@param iface: interface whose icon we want
		@type iface: L{Interface}
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
		from . import gpg
		if os.path.isabs(uri):
			old_iface = uri
		else:
			old_iface = basedir.load_first_cache(config_site, 'interfaces', escape(uri))
			if old_iface is None:
				return None
		try:
			with open(old_iface, 'rb') as stream:
				return gpg.check_stream(stream)[1]
		except SafeException as ex:
			logger.info(_("No signatures (old-style interface): %s") % ex)
			return None

	def _get_signature_date(self, uri):
		"""Read the date-stamp from the signature of the cached interface.
		If the date-stamp is unavailable, returns None.
		@type uri: str
		@rtype: int"""
		from . import trust
		sigs = self.get_cached_signatures(uri)
		if sigs:
			return self._oldest_trusted(sigs, trust.domain_from_url(uri))

	def _oldest_trusted(self, sigs, domain):
		"""Return the date of the oldest trusted signature in the list, or None if there
		are no trusted sigs in the list.
		@type sigs: [L{zeroinstall.injector.gpg.ValidSig}]
		@type domain: str
		@rtype: int"""
		trusted = [s.get_timestamp() for s in sigs if s.is_trusted(domain)]
		if trusted:
			return min(trusted)
		return None

	def get_last_check_attempt(self, url):
		"""Return the time of the most recent update attempt for a feed.
		@type url: str
		@return: The time, or None if none is recorded
		@rtype: float | None
		@see: L{mark_as_checking}"""
		timestamp_path = basedir.load_first_cache(config_site, config_prog, 'last-check-attempt', model._pretty_escape(url))
		if timestamp_path:
			return os.stat(timestamp_path).st_mtime
		return None

	def get_feed_imports(self, iface):
		"""Get all feeds that add to this interface.
		This is the feeds explicitly added by the user, feeds added by the distribution,
		and feeds imported by a <feed> in the main feed (but not recursively, at present).
		@type iface: L{Interface}
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
		@type iface: L{Interface}
		@rtype: {str: L{ZeroInstallFeed} | None}
		@since: 0.48"""
		main_feed = self.get_feed(iface.uri)
		results = {iface.uri: main_feed}
		for imp in iface.extra_feeds:
			try:
				results[imp.uri] = self.get_feed(imp.uri)
			except SafeException as ex:
				logger.warning("Failed to load feed '%s: %s", imp.uri, ex)
		if main_feed:
			for imp in main_feed.feeds:
				results[imp.uri] = self.get_feed(imp.uri)
		return results

	def get_implementations(self, iface):
		"""Return all implementations from all of iface's feeds.
		@type iface: L{Interface}
		@rtype: [L{Implementation}]
		@since: 0.48"""
		impls = []
		for feed in self.get_feeds(iface).values():
			if feed:
				impls += feed.implementations.values()
		return impls

	def get_feed_targets(self, feed):
		"""Return a list of Interfaces for which feed can be a feed.
		This is used by B{0install add-feed}.
		@param feed: the feed
		@type feed: L{model.ZeroInstallFeed} (or, deprecated, a URL)
		@rtype: [model.Interface]
		@raise SafeException: If there are no known feeds.
		@since: 0.53"""

		if not isinstance(feed, model.ZeroInstallFeed):
			# (deprecated)
			feed = self.get_feed(feed)
			if feed is None:
				raise SafeException("Feed is not cached and using deprecated API")

		if not feed.feed_for:
			raise SafeException(_("Missing <feed-for> element in '%s'; "
					"it can't be used as a feed for any other interface.") % feed.url)
		feed_targets = feed.feed_for
		logger.debug(_("Feed targets: %s"), feed_targets)
		return [self.get_interface(uri) for uri in feed_targets]

iface_cache = IfaceCache()
