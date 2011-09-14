# Copyright (C) 2011, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys

from zeroinstall import _
from zeroinstall.injector import download

def download_in_thread(url, target_file, if_modified_since, notify_done):
	try:
		from httplib import HTTPException
		from urllib2 import urlopen, Request, HTTPError, URLError
		#print "Child downloading", url
		if url.startswith('http:') or url.startswith('https:') or url.startswith('ftp:'):
			req = Request(url)
			if url.startswith('http:') and if_modified_since:
				req.add_header('If-Modified-Since', if_modified_since)
			src = urlopen(req)
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
	except (HTTPError, URLError, HTTPException) as ex:
		if isinstance(ex, HTTPError) and ex.code == 304: # Not modified
			notify_done(download.RESULT_NOT_MODIFIED)
		else:
			#print >>sys.stderr, "Error downloading '" + url + "': " + (str(ex) or str(ex.__class__.__name__))
			__, ex, tb = sys.exc_info()
			notify_done(download.RESULT_FAILED, (download.DownloadError(unicode(ex)), tb))
	except Exception as ex:
		__, ex, tb = sys.exc_info()
		notify_done(download.RESULT_FAILED, (ex, tb))
