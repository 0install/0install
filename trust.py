import os

import basedir
from namespaces import config_site, config_prog

class TrustDB:
	keys = None

	def __init__(self):
		self.keys = None
	
	def is_trusted(self, key):
		self.ensure_uptodate()
		return key in self.keys
	
	def trust_key(self, key):
		self.ensure_uptodate()
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
		trust = basedir.load_first_config(config_site, config_prog,
						'trust')
		# This is a bit inefficient...
		self.keys = {}
		if trust:
			#print "Loading trust from", trust_db
			for key in file(trust).read().split('\n'):
				self.keys[key] = True

# Singleton
trust_db = TrustDB()
