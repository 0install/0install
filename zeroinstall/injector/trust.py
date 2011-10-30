"""
Records who we trust to sign feeds.

Trust is divided up into domains, so that it is possible to trust a key
in some cases and not others.

@var trust_db: Singleton trust database instance.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, SafeException
import os
from logging import info

from zeroinstall.support import basedir, tasks
from .namespaces import config_site, config_prog, XMLNS_TRUST

KEY_INFO_TIMEOUT = 10	# Maximum time to wait for response from key-info-server

class TrustDB(object):
	"""A database of trusted keys.
	@ivar keys: maps trusted key fingerprints to a set of domains for which where it is trusted
	@type keys: {str: set(str)}
	@ivar watchers: callbacks invoked by L{notify}
	@see: L{trust_db} - the singleton instance of this class"""
	__slots__ = ['keys', 'watchers']

	def __init__(self):
		self.keys = None
		self.watchers = []
	
	def is_trusted(self, fingerprint, domain = None):
		self.ensure_uptodate()

		domains = self.keys.get(fingerprint, None)
		if not domains: return False	# Unknown key

		if domain is None:
			return True		# Deprecated

		return domain in domains or '*' in domains
	
	def get_trust_domains(self, fingerprint):
		"""Return the set of domains in which this key is trusted.
		If the list includes '*' then the key is trusted everywhere.
		@since: 0.27
		"""
		self.ensure_uptodate()
		return self.keys.get(fingerprint, set())
	
	def get_keys_for_domain(self, domain):
		"""Return the set of keys trusted for this domain.
		@since: 0.27"""
		self.ensure_uptodate()
		return set([fp for fp in self.keys
				 if domain in self.keys[fp]])

	def trust_key(self, fingerprint, domain = '*'):
		"""Add key to the list of trusted fingerprints.
		@param fingerprint: base 16 fingerprint without any spaces
		@type fingerprint: str
		@param domain: domain in which key is to be trusted
		@type domain: str
		@note: call L{notify} after trusting one or more new keys"""
		if self.is_trusted(fingerprint, domain): return

		int(fingerprint, 16)		# Ensure fingerprint is valid

		if fingerprint not in self.keys:
			self.keys[fingerprint] = set()

		#if domain == '*':
		#	warn("Calling trust_key() without a domain is deprecated")

		self.keys[fingerprint].add(domain)
		self.save()
	
	def untrust_key(self, key, domain = '*'):
		self.ensure_uptodate()
		self.keys[key].remove(domain)

		if not self.keys[key]:
			# No more domains for this key
			del self.keys[key]

		self.save()
	
	def save(self):
		from xml.dom import minidom
		import tempfile

		doc = minidom.Document()
		root = doc.createElementNS(XMLNS_TRUST, 'trusted-keys')
		root.setAttribute('xmlns', XMLNS_TRUST)
		doc.appendChild(root)

		for fingerprint in self.keys:
			keyelem = doc.createElementNS(XMLNS_TRUST, 'key')
			root.appendChild(keyelem)
			keyelem.setAttribute('fingerprint', fingerprint)
			for domain in self.keys[fingerprint]:
				domainelem = doc.createElementNS(XMLNS_TRUST, 'domain')
				domainelem.setAttribute('value', domain)
				keyelem.appendChild(domainelem)

		d = basedir.save_config_path(config_site, config_prog)
		fd, tmpname = tempfile.mkstemp(dir = d, prefix = 'trust-')
		tmp = os.fdopen(fd, 'wb')
		doc.writexml(tmp, indent = "", addindent = "  ", newl = "\n")
		tmp.close()

		os.rename(tmpname, os.path.join(d, 'trustdb.xml'))
	
	def notify(self):
		"""Call all watcher callbacks.
		This should be called after trusting or untrusting one or more new keys.
		@since: 0.25"""
		for w in self.watchers: w()
	
	def ensure_uptodate(self):
		from xml.dom import minidom

		# This is a bit inefficient... (could cache things)
		self.keys = {}

		trust = basedir.load_first_config(config_site, config_prog, 'trustdb.xml')
		if trust:
			keys = minidom.parse(trust).documentElement
			for key in keys.getElementsByTagNameNS(XMLNS_TRUST, 'key'):
				domains = set()
				self.keys[key.getAttribute('fingerprint')] = domains
				for domain in key.getElementsByTagNameNS(XMLNS_TRUST, 'domain'):
					domains.add(domain.getAttribute('value'))
		else:
			# Convert old database to XML format
			trust = basedir.load_first_config(config_site, config_prog, 'trust')
			if trust:
				#print "Loading trust from", trust_db
				for key in open(trust).read().split('\n'):
					if key:
						self.keys[key] = set(['*'])
			else:
				# No trust database found.
				# Trust Thomas Leonard's key for 0install.net by default.
				# Avoids distracting confirmation box on first run when we check
				# for updates to the GUI.
				self.keys['92429807C9853C0744A68B9AAE07828059A53CC1'] = set(['0install.net'])

def domain_from_url(url):
	"""Extract the trust domain for a URL.
	@param url: the feed's URL
	@type url: str
	@return: the trust domain
	@rtype: str
	@since: 0.27
	@raise SafeException: the URL can't be parsed"""
	import urlparse
	if os.path.isabs(url):
		raise SafeException(_("Can't get domain from a local path: '%s'") % url)
	domain = urlparse.urlparse(url)[1]
	if domain and domain != '*':
		return domain
	raise SafeException(_("Can't extract domain from URL '%s'") % url)

trust_db = TrustDB()

class TrustMgr(object):
	"""A TrustMgr handles the process of deciding whether to trust new keys
	(contacting the key information server, prompting the user, accepting automatically, etc)
	@since: 0.53"""

	__slots__ = ['config', '_current_confirm']

	def __init__(self, config):
		self.config = config
		self._current_confirm = None	# (a lock to prevent asking the user multiple questions at once)

	@tasks.async
	def confirm_keys(self, pending):
		"""We don't trust any of the signatures yet. Collect information about them and add the keys to the
		trusted list, possibly after confirming with the user (via config.handler).
		Updates the L{trust} database, and then calls L{trust.TrustDB.notify}.
		@since: 0.53
		@arg pending: an object holding details of the updated feed
		@type pending: L{PendingFeed}
		@return: A blocker that triggers when the user has chosen, or None if already done.
		@rtype: None | L{Blocker}"""

		assert pending.sigs

		from zeroinstall.injector import gpg
		valid_sigs = [s for s in pending.sigs if isinstance(s, gpg.ValidSig)]
		if not valid_sigs:
			def format_sig(sig):
				msg = str(sig)
				if sig.messages:
					msg += "\nMessages from GPG:\n" + sig.messages
				return msg
			raise SafeException(_('No valid signatures found on "%(url)s". Signatures:%(signatures)s') %
					{'url': pending.url, 'signatures': ''.join(['\n- ' + format_sig(s) for s in pending.sigs])})

		# Start downloading information about the keys...
		fetcher = self.config.fetcher
		kfs = {}
		for sig in valid_sigs:
			kfs[sig] = fetcher.fetch_key_info(sig.fingerprint)

		# Wait up to KEY_INFO_TIMEOUT seconds for key information to arrive. Avoids having the dialog
		# box update while the user is looking at it, and may allow it to be skipped completely in some
		# cases.
		timeout = tasks.TimeoutBlocker(KEY_INFO_TIMEOUT, "key info timeout")
		while True:
			key_info_blockers = [sig_info.blocker for sig_info in kfs.values() if sig_info.blocker is not None]
			if not key_info_blockers:
				break
			info("Waiting for response from key-info server: %s", key_info_blockers)
			yield [timeout] + key_info_blockers
			if timeout.happened:
				info("Timeout waiting for key info response")
				break

		# If we're already confirming something else, wait for that to finish...
		while self._current_confirm is not None:
			info("Waiting for previous key confirmations to finish")
			yield self._current_confirm

		domain = domain_from_url(pending.url)

		if self.config.auto_approve_keys:
			existing_feed = self.config.iface_cache.get_feed(pending.url)
			if not existing_feed:
				changes = False
				for sig, kf in kfs.iteritems():
					for key_info in kf.info:
						if key_info.getAttribute("vote") == "good":
							info(_("Automatically approving key for new feed %s based on response from key info server"), pending.url)
							trust_db.trust_key(sig.fingerprint, domain)
							changes = True
				if changes:
					trust_db.notify()

		# Check whether we still need to confirm. The user may have
		# already approved one of the keys while dealing with another
		# feed, or we may have just auto-approved it.
		for sig in kfs:
			is_trusted = trust_db.is_trusted(sig.fingerprint, domain)
			if is_trusted:
				return

		# Take the lock and confirm this feed
		self._current_confirm = lock = tasks.Blocker('confirm key lock')
		try:
			done = self.config.handler.confirm_import_feed(pending, kfs)
			if done is not None:
				yield done
				tasks.check(done)
		finally:
			self._current_confirm = None
			lock.trigger()
