"""
PackageKit integration.
"""

# Copyright (C) 2010, Aleksey Lim
# See the README file for details, or visit http://0install.net.

import os, sys
import locale
import logging
from zeroinstall import _, SafeException

from zeroinstall.support import tasks
from zeroinstall.injector import download, model

_logger_pk = logging.getLogger('packagekit')

try:
	import dbus
	import dbus.mainloop.glib
	dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
except Exception as ex:
	_logger_pk.info("D-BUS not available: %s", ex)
	dbus = None

MAX_PACKAGE_KIT_TRANSACTION_SIZE = 100

class PackageKit(object):
	def __init__(self):
		self._pk = False

		self._candidates = {}	# { package_name : [ (version, arch, size) ] | Blocker }

		# PackageKit is really slow at handling separate queries, so we use this to
		# batch them up.
		self._next_batch = set()

	@property
	def available(self):
		return self.pk is not None

	@property
	def pk(self):
		if self._pk is False:
			if dbus is None:
				self._pk = None
			else:
				try:
					self._pk = dbus.Interface(dbus.SystemBus().get_object(
								'org.freedesktop.PackageKit',
								'/org/freedesktop/PackageKit', False),
							'org.freedesktop.PackageKit')
					_logger_pk.info(_('PackageKit dbus service found'))
				except Exception as ex:
					_logger_pk.info(_('PackageKit dbus service not found: %s'), ex)
					self._pk = None
		return self._pk

	def get_candidates(self, package_name, factory, prefix):
		"""Add any cached candidates.
		The candidates are those discovered by a previous call to L{fetch_candidates}.
		@param package_name: the distribution's name for the package
		@param factory: a function to add a new implementation to the feed
		@param prefix: the prefix for the implementation's ID
		"""
		candidates = self._candidates.get(package_name, None)
		if candidates is None:
			return

		if isinstance(candidates, tasks.Blocker):
			return		# Fetch still in progress

		for candidate in candidates:
			impl_name = '%s:%s:%s:%s' % (prefix, package_name, candidate['version'], candidate['arch'])

			impl = factory(impl_name, only_if_missing = True, installed = candidate['installed'])
			if impl is None:
				# (checking this way because the cached candidate['installed'] may be stale)
				return		# Already installed

			impl.version = model.parse_version(candidate['version'])
			if candidate['arch'] != '*':
				impl.machine = candidate['arch']

			def install(handler):
				packagekit_id = candidate['packagekit_id']
				dl = PackageKitDownload('packagekit:' + packagekit_id, hint = impl, pk = self.pk, packagekit_id = packagekit_id, expected_size = candidate['size'])
				handler.monitor_download(dl)
				return dl.downloaded
			impl.download_sources.append(model.DistributionSource(package_name, candidate['size'], install))

	@tasks.async
	def fetch_candidates(self, package_names):
		assert self.pk

		# Batch requests up
		self._next_batch |= set(package_names)
		yield
		package_names = self._next_batch
		self._next_batch = set()
		# The first fetch_candidates instance will now have all the packages
		# For the others, package_names will now be empty

		known = [self._candidates[p] for p in package_names if p in self._candidates]
		# (use set because a single task may be checking multiple packages and we need
		# to avoid duplicates).
		in_progress = list(set([b for b in known if isinstance(b, tasks.Blocker)]))
		_logger_pk.debug('Already downloading: %s', in_progress)

		# Filter out the ones we've already fetched
		package_names = [p for p in package_names if p not in self._candidates]

		def do_batch(package_names):
			#_logger_pk.info("sending %d packages in batch", len(package_names))
			versions = {}

			blocker = None

			def error_cb(sender):
				# Note: probably just means the package wasn't found
				_logger_pk.info(_('Transaction failed: %s(%s)'), sender.error_code, sender.error_details)
				blocker.trigger()

			def details_cb(sender):
				for packagekit_id, info in versions.items():
					if packagekit_id in sender.details:
						info.update(sender.details[packagekit_id])
						info['packagekit_id'] = packagekit_id
						if (info['name'] not in self._candidates or
						    isinstance(self._candidates[info['name']], tasks.Blocker)):
							self._candidates[info['name']] = [info]
						else:
							self._candidates[info['name']].append(info)
					else:
						_logger_pk.info(_('Empty details for %s'), packagekit_id)
				blocker.trigger()

			def resolve_cb(sender):
				if sender.package:
					for packagekit_id, info in sender.package.iteritems():
						parts = packagekit_id.split(';', 3)
						if ':' in parts[3]:
							parts[3] = parts[3].split(':', 1)[0]
							packagekit_id = ';'.join(parts)
						versions[packagekit_id] = info
					tran = _PackageKitTransaction(self.pk, details_cb, error_cb)
					tran.proxy.GetDetails(versions.keys())
				else:
					_logger_pk.info(_('Empty resolve for %s'), package_names)
					blocker.trigger()

			# Send queries
			blocker = tasks.Blocker('PackageKit %s' % package_names)
			for package in package_names:
				self._candidates[package] = blocker

			try:
				_logger_pk.debug(_('Ask for %s'), package_names)
				tran = _PackageKitTransaction(self.pk, resolve_cb, error_cb)
				tran.proxy.Resolve('none', package_names)

				in_progress.append(blocker)
			except:
				__, ex, tb = sys.exc_info()
				blocker.trigger((ex, tb))
				raise

		# Now we've collected all the requests together, split them up into chunks
		# that PackageKit can handle ( < 100 per batch )
		#_logger_pk.info("sending %d packages", len(package_names))
		while package_names:
			next_batch = package_names[:MAX_PACKAGE_KIT_TRANSACTION_SIZE]
			package_names = package_names[MAX_PACKAGE_KIT_TRANSACTION_SIZE:]
			do_batch(next_batch)

		while in_progress:
			yield in_progress
			in_progress = [b for b in in_progress if not b.happened]

class PackageKitDownload:
	def __init__(self, url, hint, pk, packagekit_id, expected_size):
		self.url = url
		self.status = download.download_fetching
		self.hint = hint
		self.aborted_by_user = False

		self.downloaded = None

		self.expected_size = expected_size

		self.packagekit_id = packagekit_id
		self._impl = hint
		self._transaction = None
		self.pk = pk

		def error_cb(sender):
			self.status = download.download_failed
			ex = SafeException('PackageKit install failed: %s' % (sender.error_details or sender.error_code))
			self.downloaded.trigger(exception = (ex, None))

		def installed_cb(sender):
			self._impl.installed = True
			self.status = download.download_complete
			self.downloaded.trigger()

		def install_packages():
			package_name = self.packagekit_id
			self._transaction = _PackageKitTransaction(self.pk, installed_cb, error_cb)
			self._transaction.compat_call([
					('InstallPackages', False, [package_name]),
					('InstallPackages', [package_name]),
					])

		_auth_wrapper(install_packages)

		self.downloaded = tasks.Blocker('PackageKit install %s' % self.packagekit_id)

	def abort(self):
		_logger_pk.debug(_('Cancel transaction'))
		self.aborted_by_user = True
		self._transaction.proxy.Cancel()
		self.status = download.download_failed
		self.downloaded.trigger()

	def get_current_fraction(self):
		if self._transaction is None:
			return None
		percentage = self._transaction.getPercentage()
		if percentage > 100:
			return None
		else:
			return float(percentage) / 100.

	def get_bytes_downloaded_so_far(self):
		fraction = self.get_current_fraction()
		if fraction is None:
			return 0
		else:
			if self.expected_size is None:
				return 0
			return int(self.expected_size * fraction)

def _auth_wrapper(method, *args):
	try:
		return method(*args)
	except dbus.exceptions.DBusException as e:
		if e.get_dbus_name() != \
				'org.freedesktop.PackageKit.Transaction.RefusedByPolicy':
			raise

		iface, auth = e.get_dbus_message().split()
		if not auth.startswith('auth_'):
			raise

		_logger_pk.debug(_('Authentication required for %s'), auth)

		pk_auth = dbus.SessionBus().get_object(
				'org.freedesktop.PolicyKit.AuthenticationAgent', '/',
				'org.gnome.PolicyKit.AuthorizationManager.SingleInstance')

		if not pk_auth.ObtainAuthorization(iface, dbus.UInt32(0),
				dbus.UInt32(os.getpid()), timeout=300):
			raise

		return method(*args)

class _PackageKitTransaction(object):
	def __init__(self, pk, finished_cb=None, error_cb=None):
		self._finished_cb = finished_cb
		self._error_cb = error_cb
		self.error_code = None
		self.error_details = None
		self.package = {}
		self.details = {}
		self.files = {}

		self.object = dbus.SystemBus().get_object(
				'org.freedesktop.PackageKit', pk.GetTid(), False)
		self.proxy = dbus.Interface(self.object,
				'org.freedesktop.PackageKit.Transaction')
		self._props = dbus.Interface(self.object, dbus.PROPERTIES_IFACE)

		self._signals = []
		for signal, cb in [('Finished', self.__finished_cb),
				   ('ErrorCode', self.__error_code_cb),
				   ('StatusChanged', self.__status_changed_cb),
				   ('Package', self.__package_cb),
				   ('Details', self.__details_cb),
				   ('Files', self.__files_cb)]:
			self._signals.append(self.proxy.connect_to_signal(signal, cb))

		defaultlocale = locale.getdefaultlocale()[0]
		if defaultlocale is not None:
			self.compat_call([
					('SetHints', ['locale=%s' % defaultlocale]),
					('SetLocale', defaultlocale),
					])

	def getPercentage(self):
		result = self.get_prop('Percentage')
		if result is None:
			result, __, __, __ = self.proxy.GetProgress()
		return result

	def get_prop(self, prop, default = None):
		try:
			return self._props.Get('org.freedesktop.PackageKit.Transaction', prop)
		except:
			return default

	# note: Ubuntu's aptdaemon implementation of PackageKit crashes if passed the wrong
	# arguments (rather than returning InvalidArgs), so always try its API first.
	def compat_call(self, calls):
		for call in calls:
			method = call[0]
			args = call[1:]
			try:
				dbus_method = self.proxy.get_dbus_method(method)
				return dbus_method(*args)
			except dbus.exceptions.DBusException as e:
				if e.get_dbus_name() not in (
				   'org.freedesktop.DBus.Error.UnknownMethod',
				   'org.freedesktop.DBus.Error.InvalidArgs'):
					raise
		raise Exception('Cannot call %r DBus method' % calls)

	def __finished_cb(self, exit, runtime):
		_logger_pk.debug(_('Transaction finished: %s'), exit)

		for i in self._signals:
			i.remove()

		if self.error_code is not None:
			self._error_cb(self)
		else:
			self._finished_cb(self)

	def __error_code_cb(self, code, details):
		_logger_pk.info(_('Transaction failed: %s(%s)'), details, code)
		self.error_code = code
		self.error_details = details

	def __package_cb(self, status, id, summary):
		try:
			from zeroinstall.injector import distro

			package_name, version, arch, repo_ = id.split(';')
			clean_version = distro.try_cleanup_distro_version(version)
			if not clean_version:
				_logger_pk.warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package_name})
				return
			clean_arch = distro.canonical_machine(arch)
			package = {'version': clean_version,
				   'name': package_name,
				   'arch': clean_arch,
				   'installed': (status == 'installed')}
			_logger_pk.debug(_('Package: %s %r'), id, package)
			self.package[str(id)] = package
		except Exception as ex:
			_logger_pk.warn("__package_cb(%s, %s, %s): %s", status, id, summary, ex)

	def __details_cb(self, id, licence, group, detail, url, size):
		details = {'licence': str(licence),
				   'group': str(group),
				   'detail': str(detail),
				   'url': str(url),
				   'size': int(size)}
		_logger_pk.debug(_('Details: %s %r'), id, details)
		self.details[id] = details

	def __files_cb(self, id, files):
		self.files[id] = files.split(';')

	def __status_changed_cb(self, status):
		pass
