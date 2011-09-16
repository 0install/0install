# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os, socket, ssl

from zeroinstall import _
from zeroinstall.injector import download

import urllib2, httplib

# This works on Debian. It probably needs to be updated to handle other platforms.
ca_file = "/etc/ssl/certs/ca-certificates.crt"

if os.path.exists(ca_file):
	class ValidatingHTTPSConnection(httplib.HTTPSConnection):
		def connect(self):
			sock = socket.create_connection((self.host, self.port), self.timeout)
			if self._tunnel_host:
				self.sock = sock
				self._tunnel()
			self.sock = ssl.wrap_socket(sock, cert_reqs = ssl.CERT_REQUIRED, ca_certs = ca_file)

	class ValidatingHTTPSHandler(urllib2.HTTPSHandler):
		def https_open(self, req):
			return self.do_open(self.getConnection, req)

		def getConnection(self, host, timeout=300):
			return ValidatingHTTPSConnection(host)

	urlopener = urllib2.build_opener(ValidatingHTTPSHandler)

	# Builds an opener that overrides the default HTTPS handler with our one
	_my_urlopen = urllib2.build_opener(ValidatingHTTPSHandler()).open
else:
	_my_urlopen = urllib2.urlopen

def download_in_thread(url, target_file, if_modified_since, notify_done):
	try:
		#print "Child downloading", url
		if url.startswith('http:') or url.startswith('https:') or url.startswith('ftp:'):
			req = urllib2.Request(url)
			if url.startswith('http:') and if_modified_since:
				req.add_header('If-Modified-Since', if_modified_since)
			src = _my_urlopen(req)
		else:
			raise Exception(_('Unsupported URL protocol in: %s') % url)

		try:
			sock = src.fp._sock
		except AttributeError:
			sock = src.fp.fp._sock	# Python 2.5 on FreeBSD
		while True:
			data = sock.recv(256)
			if not data: break
			target_file.write(data)
			target_file.flush()

		notify_done(download.RESULT_OK)
	except (urllib2.HTTPError, urllib2.URLError, httplib.HTTPException) as ex:
		if isinstance(ex, urllib2.HTTPError) and ex.code == 304: # Not modified
			notify_done(download.RESULT_NOT_MODIFIED)
		else:
			#print >>sys.stderr, "Error downloading '" + url + "': " + (str(ex) or str(ex.__class__.__name__))
			__, ex, tb = sys.exc_info()
			notify_done(download.RESULT_FAILED, (download.DownloadError(unicode(ex)), tb))
	except Exception as ex:
		__, ex, tb = sys.exc_info()
		notify_done(download.RESULT_FAILED, (ex, tb))
