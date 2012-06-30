# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os, socket, ssl

from zeroinstall import _
from zeroinstall.injector import download
from zeroinstall.support import ssl_match_hostname

if sys.version_info[0] > 2:
	from urllib import request as urllib2
	from http.client import HTTPSConnection, HTTPException
else:
	import urllib2
	from httplib import HTTPSConnection, HTTPException

try:
	# http://pypi.python.org/pypi/certifi
	import certifi
	_fallback_ca_bundle = certifi.where()
except:
	# Final fallback (last known signer of keylookup)
	_fallback_ca_bundle = os.path.join(os.path.dirname(__file__), "EquifaxSecureCA.crt")

# Note: on MacOS X at least, it will also look in the system keychain provided that you supply *some* CAs.
# (if you don't specify any trusted CAs, Python trusts everything!)
# So, the "fallback" option doesn't necessarily mean that other sites won't work.
for ca_bundle in [
		"/etc/ssl/certs/ca-certificates.crt",	# Debian/Ubuntu/Arch Linux
		"/etc/pki/tls/certs/ca-bundle.crt",	# Fedora/RHEL
		"/etc/ssl/ca-bundle.pem",		# openSUSE/SLE (claimed)
		"/var/lib/ca-certificates/ca-bundle.pem.new", # openSUSE (actual)
		_fallback_ca_bundle]:
	if os.path.exists(ca_bundle):
		class ValidatingHTTPSConnection(HTTPSConnection):
			def connect(self):
				sock = socket.create_connection((self.host, self.port), self.timeout)
				if hasattr(self, '_tunnel_host') and self._tunnel_host:
					self.sock = sock
					self._tunnel()
				sock = ssl.wrap_socket(sock, cert_reqs = ssl.CERT_REQUIRED, ca_certs = ca_bundle)
				ssl_match_hostname.match_hostname(sock.getpeercert(), self.host)
				self.sock = sock

		class ValidatingHTTPSHandler(urllib2.HTTPSHandler):
			def https_open(self, req):
				return self.do_open(self.getConnection, req)

			def getConnection(self, host, timeout=300):
				return ValidatingHTTPSConnection(host)
		MyHTTPSHandler = ValidatingHTTPSHandler
		break
else:
	raise Exception("No root CA's found (not even the built-in one!); security of HTTPS connections cannot be verified")

class Redirect(Exception):
	def __init__(self, req):
		Exception.__init__(self, "Redirect")
		self.req = req

class MyRedirectHandler(urllib2.HTTPRedirectHandler):
	"""Throw an exception on redirects instead of continuing. The redirect will be handled in the main thread
	so it can work with connection pooling."""
	def redirect_request(self, req, fp, code, msg, headers, newurl):
		new_req = urllib2.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
		if new_req:
			raise Redirect(new_req)

# Our handler differs from the Python default in that:
# - we don't support file:// URLs
# - we don't follow HTTP redirects
_my_urlopen = urllib2.OpenerDirector()
for klass in [urllib2.ProxyHandler, urllib2.UnknownHandler, urllib2.HTTPHandler,
                       urllib2.HTTPDefaultErrorHandler, MyRedirectHandler,
		       urllib2.FTPHandler, urllib2.HTTPErrorProcessor, MyHTTPSHandler]:
	_my_urlopen.add_handler(klass())

def download_in_thread(url, target_file, if_modified_since, notify_done):
	try:
		#print "Child downloading", url
		if url.startswith('http:') or url.startswith('https:') or url.startswith('ftp:'):
			req = urllib2.Request(url)
			if url.startswith('http:') and if_modified_since:
				req.add_header('If-Modified-Since', if_modified_since)
			src = _my_urlopen.open(req)
		else:
			raise Exception(_('Unsupported URL protocol in: %s') % url)

		if sys.version_info[0] > 2:
			sock_recv = src.fp.read1		# Python 3
		else:
			try:
				sock_recv = src.fp._sock.recv	# Python 2
			except AttributeError:
				sock_recv = src.fp.fp._sock.recv	# Python 2.5 on FreeBSD
		while True:
			data = sock_recv(256)
			if not data: break
			target_file.write(data)
			target_file.flush()

		notify_done(download.RESULT_OK)
	except (urllib2.HTTPError, urllib2.URLError, HTTPException, socket.error) as ex:
		if isinstance(ex, urllib2.HTTPError) and ex.code == 304: # Not modified
			notify_done(download.RESULT_NOT_MODIFIED)
		else:
			#print >>sys.stderr, "Error downloading '" + url + "': " + (str(ex) or str(ex.__class__.__name__))
			__, ex, tb = sys.exc_info()
			notify_done(download.RESULT_FAILED, (download.DownloadError(_('Error downloading {url}: {ex}').format(url = url, ex = ex)), tb))
	except Redirect as ex:
		notify_done(download.RESULT_REDIRECT, redirect = ex.req.get_full_url())
	except Exception as ex:
		__, ex, tb = sys.exc_info()
		notify_done(download.RESULT_FAILED, (ex, tb))
