# Copyright (C) 2010, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(__file__))))

from zeroinstall import _

# NB: duplicated in download.py
RESULT_OK = 0
RESULT_FAILED = 1
RESULT_NOT_MODIFIED = 2

def _download_as_child(url, if_modified_since):
	from httplib import HTTPException
	from urllib2 import urlopen, Request, HTTPError, URLError
	try:
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
			os.write(1, data)

		sys.exit(RESULT_OK)
	except (HTTPError, URLError, HTTPException), ex:
		if isinstance(ex, HTTPError) and ex.code == 304: # Not modified
			sys.exit(RESULT_NOT_MODIFIED)
		print >>sys.stderr, "Error downloading '" + url + "': " + (str(ex) or str(ex.__class__.__name__))
		sys.exit(RESULT_FAILED)

if __name__ == '__main__':
	assert (len(sys.argv) == 2) or (len(sys.argv) == 3), "Usage: download URL [If-Modified-Since-Date], not %s" % sys.argv
	if len(sys.argv) >= 3:
		if_modified_since_date = sys.argv[2]
	else:
		if_modified_since_date = None
	_download_as_child(sys.argv[1], if_modified_since_date)
