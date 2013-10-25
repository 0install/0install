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

from zeroinstall.support import basedir
from .namespaces import config_site, config_prog, XMLNS_TRUST

class TrustDB(object):
	"""A database of trusted keys.
	@ivar keys: maps trusted key fingerprints to a set of domains for which where it is trusted
	@type keys: {str: set(str)}
	@ivar watchers: callbacks invoked by L{notify}
	@see: L{trust_db} - the singleton instance of this class"""
	__slots__ = ['keys', 'watchers', '_dry_run']

	def __init__(self):
		self.keys = None
		self.watchers = []
		self._dry_run = False
	
	def is_trusted(self, fingerprint, domain = None):
		"""@type fingerprint: str
		@type domain: str | None
		@rtype: bool"""
		self.ensure_uptodate()

		domains = self.keys.get(fingerprint, None)
		if not domains: return False	# Unknown key

		if domain is None:
			return True		# Deprecated

		return domain in domains or '*' in domains
	
	def get_trust_domains(self, fingerprint):
		"""Return the set of domains in which this key is trusted.
		If the list includes '*' then the key is trusted everywhere.
		@type fingerprint: str
		@rtype: {str}
		@since: 0.27"""
		self.ensure_uptodate()
		return self.keys.get(fingerprint, set())
	
	def get_keys_for_domain(self, domain):
		"""Return the set of keys trusted for this domain.
		@type domain: str
		@rtype: {str}
		@since: 0.27"""
		self.ensure_uptodate()
		return set([fp for fp in self.keys
				 if domain in self.keys[fp]])

	def ensure_uptodate(self):
		if self._dry_run:
			if self.keys is None: self.keys = {}
			return
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
				with open(trust, 'rt') as stream:
					for key in stream:
						if key:
							self.keys[key] = set(['*'])

def domain_from_url(url):
	"""Extract the trust domain for a URL.
	@param url: the feed's URL
	@type url: str
	@return: the trust domain
	@rtype: str
	@since: 0.27
	@raise SafeException: the URL can't be parsed"""
	try:
		import urlparse
	except ImportError:
		from urllib import parse as urlparse	# Python 3

	if os.path.isabs(url):
		raise SafeException(_("Can't get domain from a local path: '%s'") % url)
	domain = urlparse.urlparse(url)[1]
	if domain and domain != '*':
		return domain
	raise SafeException(_("Can't extract domain from URL '%s'") % url)

trust_db = TrustDB()
