"""
Records who we trust to sign interfaces.

Trust is divided up into domains, so that it is possible to trust a key
in some cases and not others.

@var trust_db: Singleton trust database instance.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os

from zeroinstall.support import basedir
from namespaces import config_site, config_prog, XMLNS_TRUST

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
				for key in file(trust).read().split('\n'):
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
	from zeroinstall import SafeException
	if url.startswith('/'):
		raise SafeException(_("Can't get domain from a local path: '%s'") % url)
	domain = urlparse.urlparse(url)[1]
	if domain and domain != '*':
		return domain
	raise SafeException(_("Can't extract domain from URL '%s'") % url)

trust_db = TrustDB()
