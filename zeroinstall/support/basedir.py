"""
Support code for the freedesktop.org basedir spec.

This module provides functions for locating configuration files.

@see: U{http://freedesktop.org/wiki/Standards/basedir-spec}

@var home: The value of $HOME (or '/' if not set). If we're running as root and
$HOME isn't owned by root, then this will be root's home from /etc/passwd
instead.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os

home = os.environ.get('HOME', '/')

try:
	_euid = os.geteuid()
except AttributeError:
	pass	# Windows?
else:
	if _euid == 0:
		# We're running as root. Ensure that $HOME really is root's home,
		# not the user's home, or we're likely to fill it will unreadable
		# root-owned files.
		home_owner = os.stat(home).st_uid
		if home_owner != 0:
			import pwd
			from logging import info
			old_home = home
			home = pwd.getpwuid(0).pw_dir or '/'
			info(_("$HOME (%(home)s) is owned by user %(user)d, but we are root (0). Using %(root_home)s instead."), {'old_home': old_home, 'user': home_owner, 'root_home': home})
			del old_home
			del home_owner

if os.name == "nt":
	from win32com.shell import shell, shellcon
	appData = shell.SHGetFolderPath(0, shellcon.CSIDL_APPDATA, 0, 0)
	localAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_LOCAL_APPDATA, 0, 0)
	commonAppData = shell.SHGetFolderPath(0, shellcon.CSIDL_COMMON_APPDATA, 0, 0)

	xdg_data_home = appData
	xdg_data_dirs = [xdg_data_home, commonAppData]

	xdg_cache_home = localAppData
	xdg_cache_dirs = [xdg_cache_home, commonAppData]

	xdg_config_home = appData
	xdg_config_dirs = [xdg_config_home, commonAppData]
else:
	xdg_data_home = os.environ.get('XDG_DATA_HOME',
				os.path.join(home, '.local', 'share'))

	xdg_data_dirs = [xdg_data_home] + \
		os.environ.get('XDG_DATA_DIRS', '/usr/local/share:/usr/share').split(':')

	xdg_cache_home = os.environ.get('XDG_CACHE_HOME',
				os.path.join(home, '.cache'))

	xdg_cache_dirs = [xdg_cache_home] + \
		os.environ.get('XDG_CACHE_DIRS', '/var/cache').split(':')

	xdg_config_home = os.environ.get('XDG_CONFIG_HOME',
				os.path.join(home, '.config'))

	xdg_config_dirs = [xdg_config_home] + \
		os.environ.get('XDG_CONFIG_DIRS', '/etc/xdg').split(':')

xdg_data_dirs = filter(lambda x: x, xdg_data_dirs)
xdg_cache_dirs = filter(lambda x: x, xdg_cache_dirs)
xdg_config_dirs = filter(lambda x: x, xdg_config_dirs)

def save_config_path(*resource):
	"""Ensure $XDG_CONFIG_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application. Use this
	when SAVING configuration settings. Use the xdg_config_dirs variable
	for loading."""
	resource = os.path.join(*resource)
	assert not os.path.isabs(resource)
	path = os.path.join(xdg_config_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0700)
	return path

def load_config_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	configuration search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's config dir comes first)."""
	resource = os.path.join(*resource)
	for config_dir in xdg_config_dirs:
		path = os.path.join(config_dir, resource)
		if os.path.exists(path): yield path

def load_first_config(*resource):
	"""Returns the first result from load_config_paths, or None if there is nothing
	to load."""
	for x in load_config_paths(*resource):
		return x
	return None

def save_cache_path(*resource):
	"""Ensure $XDG_CACHE_HOME/<resource>/ exists, and return its path.
	'resource' should normally be the name of your application."""
	resource = os.path.join(*resource)
	assert not os.path.isabs(resource)
	path = os.path.join(xdg_cache_home, resource)
	if not os.path.isdir(path):
		os.makedirs(path, 0700)
	return path

def load_cache_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	cache search path. Information provided by earlier directories should
	take precedence over later ones (ie, the user's cache dir comes first)."""
	resource = os.path.join(*resource)
	for cache_dir in xdg_cache_dirs:
		path = os.path.join(cache_dir, resource)
		if os.path.exists(path): yield path

def load_first_cache(*resource):
	"""Returns the first result from load_cache_paths, or None if there is nothing
	to load."""
	for x in load_cache_paths(*resource):
		return x
	return None

def load_data_paths(*resource):
	"""Returns an iterator which gives each directory named 'resource' in the
	shared data search path. Information provided by earlier directories should
	take precedence over later ones.
	@since: 0.28"""
	resource = os.path.join(*resource)
	for data_dir in xdg_data_dirs:
		path = os.path.join(data_dir, resource)
		if os.path.exists(path): yield path

def load_first_data(*resource):
	"""Returns the first result from load_data_paths, or None if there is nothing
	to load.
	@since: 0.28"""
	for x in load_data_paths(*resource):
		return x
	return None
