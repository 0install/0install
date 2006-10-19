"""
Records who we trust to sign interfaces.

@var trust_db: Singleton trust database instance.
"""

# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

import basedir
from namespaces import config_site, config_prog

class TrustDB:
	"""A database of trusted keys.
	@ivar keys: a list of trusted key fingerprints
	@see: L{trust_db} - the singleton instance of this class"""
	keys = None

	def __init__(self):
		self.keys = None
	
	def is_trusted(self, key):
		self.ensure_uptodate()
		return key in self.keys
	
	def trust_key(self, key):
		self.ensure_uptodate()
		if key in self.keys: return
		int(key, 16)		# Ensure fingerprint is valid
		self.keys[key] = True
		self.save()
	
	def untrust_key(self, key):
		self.ensure_uptodate()
		del self.keys[key]
		self.save()
	
	def save(self):
		d = basedir.save_config_path(config_site, config_prog)
		# XXX
		f = file(os.path.join(d, 'trust'), 'w')
		for key in self.keys:
			print >>f, key
		f.close()
	
	def ensure_uptodate(self):
		# This is a bit inefficient...
		trust = basedir.load_first_config(config_site, config_prog,
						'trust')
		# By default, trust our own key
		self.keys = {}
		if trust:
			#print "Loading trust from", trust_db
			for key in file(trust).read().split('\n'):
				if key:
					self.keys[key] = True

trust_db = TrustDB()
