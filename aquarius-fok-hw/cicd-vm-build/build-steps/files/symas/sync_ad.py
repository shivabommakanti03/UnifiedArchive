#!/usr/bin/env python

from __future__ import print_function

import logging
logger = logging.getLogger("sync_ad")

import argparse
import itertools
import ldap
import ldap.modlist
import logging
import subprocess
import sys

if "3".split('.') > ldap.__version__.split('.'):
    raise RuntimeError("Need python-ldap version 3.0 or higher")

if sys.version_info.major == 2:
    from ConfigParser import ConfigParser
else:
    from configparser import ConfigParser
from ldap.ldapobject import LDAPObject
from ldap.cidict import cidict as CIDict
from ldap.controls.sss import SSSRequestControl
from ldap.filter import filter_format
from ldapurl import LDAPUrl
from pprint import pformat
if sys.version_info.major == 2:
    from textwrap import TextWrapper
    indent = lambda text, prefix: "\n".join(prefix + line for line in text.split('\n'))
else:
    from textwrap import indent


ADD_PINN_USER = ['/root/bin/add_pinn_user.pl']
CONFIG_PATH = '/etc/symas/provisioning/provisioning.conf'
FILTER_TEMPLATE = "(&(objectCategory=person)(objectClass=user)(memberOf:1.2.840.113556.1.4.1941:=%s))"
GROUP_ID = 'group'
USER_ID = 'user'
VERBOSITY = 0

parser = argparse.ArgumentParser()
parser.add_argument('-c', '--config', default=CONFIG_PATH, help='configuration file')
parser.add_argument('-v', '--verbose', action='count', help='increase verbosity by one')

parser.add_argument('args', nargs='*', help='extra args for the batch consumer')


if sys.version_info.major == 2:
    to_hex = lambda x : ''.join("%02x" % ord(c) for c in x)
else:
    to_hex = lambda x: x.hex()

def pretty_format(value, offset=4, verbosity=1):
    "Formats the value, indenting if needed"
    if VERBOSITY >= 0 and VERBOSITY < verbosity:
        return '(run with verbosity >= %d to show)' % verbosity

    string = pformat(value)
    if '\n' in string:
        string = string[:1] + '\n' + indent(' ' + string[1:], ' '*offset)
    return string

def decode_as_UUID(raw_uuid):
    if len(raw_uuid) != 16:
        raise ValueError

    return "-".join([
        to_hex(raw_uuid[:4]),
        to_hex(raw_uuid[4:6]),
        to_hex(raw_uuid[6:8]),
        to_hex(raw_uuid[8:10]),
        to_hex(raw_uuid[10:]),
    ])

def get_connection(config):
    conn = LDAPObject(config['uri'])
    conn.protocol_version = ldap.VERSION3

    uri = LDAPUrl(config['uri'])

    reset_tls_ctx = False
    for option_name, value in config.items():
        option = getattr(ldap, 'OPT_X_' + option_name.upper(), None)
        if option:
            logger.debug("Setting option %s(%s) to %s", option_name, option, value)
            conn.set_option(option, value)
            if option_name.upper().startswith('TLS_'):
                reset_tls_ctx = True
    if reset_tls_ctx:
        logger.debug("A TLS option was set, resetting the TLS context")
        conn.set_option(ldap.OPT_X_TLS_NEWCTX, 0)

    if uri.urlscheme == 'ldaps':
        starttls = config.get('starttls', 'yes')
        if starttls != 'no':
            try:
                conn.start_tls_s()
            except ldap.SERVER_DOWN:
                if starttls == 'hard':
                    logger.exception("Cannot set up a TLS layer")
                    raise
                logger.warning("Cannot set up a TLS layer, "
                               "configuration says to proceed anyway")

    if config:
        mechanism = config.get('mechanism', 'simple')
        if mechanism == 'simple':
            if config.get('authz_id'):
                raise NotImplementedError
            logger.debug("binding as %s", config['binddn'])
            conn.bind_s(config['binddn'], config['password'])
        else:
            conn.sasl_non_interactive_bind_s(mechanism.upper(),
                                             authz_id=config.get('authz_id', ''))

    return conn

def ordered_zip(left, right):
    try:
        l = next(left)
    except StopIteration:
        l = None
    try:
        r = next(right)
    except StopIteration:
        r = None

    while l and r:
        l_uuid, l_attrs = l
        r_uuid, r_attrs = r

        if l_uuid < r_uuid:
            yield (l_attrs, None)
            l = None
        elif l_uuid > r_uuid:
            yield (None, r_attrs)
            r = None
        else:
            yield (l_attrs, r_attrs)
            l = r = None

        if not l:
            try:
                l = next(left)
            except StopIteration:
                l = None
        if not r:
            try:
                r = next(right)
            except StopIteration:
                r = None

    if l:
        yield (l[1], None)
        for l in left:
            yield (l[1], None)
    elif r:
        yield (None, r[1])
        for r in right:
            yield (None, r[1])


class SyncAD(object):
    def __init__(self, config):
        self.config = config

        self.ad_reader = get_connection(config['upstream'])
        self.openldap_reader = get_connection(config['connection'])
        self.openldap_writer = get_connection(config['connection'])

        self._ad_msgid = None
        self._openldap_msgid = None

    def _start_ad_sync(self):
        conn_config = self.config['upstream']

        sss_control = SSSRequestControl(
            criticality=True,
            ordering_rules=['objectGUID'])

        filterstr = filter_format(FILTER_TEMPLATE, [self.config['handler']['group_dn']])

        search_args = {
            'scope': ldap.SCOPE_SUBTREE,
            'attrlist': ['*', '+'],
            'filterstr': filterstr,
            'serverctrls': [sss_control],
        }

        self._ad_msgid = self.ad_reader.search_ext(conn_config['base'], **search_args)
        logger.info("Starting AD search msgid=%d base='%s' args=%r", self._ad_msgid, conn_config['base'], search_args)

    def _start_openldap_sync(self):
        conn_config = self.config['connection']

        sss_control = SSSRequestControl(
            criticality=True,
            ordering_rules=['provisioningLink', 'provisioningId'])

        search_args = {
            'scope': ldap.SCOPE_SUBTREE,
            'attrlist': ['*', '+'],
            'filterstr': "(provisioningLink=*)",
            'serverctrls': [sss_control],
        }

        self._openldap_msgid = self.openldap_reader.search_ext(conn_config['base'], **search_args)
        logger.info("Starting OpenLDAP search msgid=%d base=%r args=%r", self._openldap_msgid, conn_config['base'], search_args)

    def _ad_entries(self):
        while True:
            msgtype, data = self.ad_reader.result(msgid=self._ad_msgid, all=0)

            if msgtype == ldap.RES_SEARCH_RESULT:
                logger.info("AD search finished")
                self._ad_msgid = None
                return
            elif msgtype == ldap.RES_SEARCH_ENTRY:
                for dn, attrs in data:
                    entry_dict = CIDict(attrs)
                    entry_dict['dn'] = dn
                    uuid = entry_dict['entryUUID'] = [decode_as_UUID(x) for x in entry_dict['objectGUID']]
                    yield uuid[0], entry_dict
            elif msgtype == ldap.RES_SEARCH_REFERENCE:
                logger.debug("Ignoring search reference from AD %s", pretty_format(data))
            else:
                logger.error("Unexpected msgtype %s for a search request from AD", msgtype)

    def _openldap_entries(self):
        current_entry = CIDict()
        uuid = None
        while True:
            msgtype, data = self.openldap_reader.result(msgid=self._openldap_msgid, all=0)

            if msgtype == ldap.RES_SEARCH_RESULT:
                logger.info("OpenLDAP search finished")
                self._openldap_msgid = None

                if current_entry:
                    yield uuid, current_entry
                return
            elif msgtype == ldap.RES_SEARCH_ENTRY:
                for dn, attrs in data:
                    entry_dict = CIDict(attrs)
                    entry_dict['dn'] = dn

                    new_uuid = entry_dict['provisioningLink'][0]
                    if uuid and uuid != new_uuid:
                        yield uuid, current_entry
                        current_entry = CIDict()
                        uuid = new_uuid

                    entry_type = entry_dict['provisioningId'][0]
                    current_entry[entry_type] = entry_dict
                    uuid = new_uuid
            elif msgtype == ldap.RES_SEARCH_REFERENCE:
                logger.debug("Ignoring search reference from OpenLDAP %s", pretty_format(data))
            else:
                logger.error("Unexpected msgtype %s for a search request from OpenLDAP", msgtype)

    def add_user(self, uid, ad_entry):
        arguments = {}

        arguments['-n'] = uid[0]
        arguments['-f'] = ad_entry.get('fullName', uid)[0]
        arguments['-e'] = ad_entry['mail']
        arguments['-a'] = ad_entry['dn']
        arguments['-r'] = self.config['handler']['domain']

        args = ADD_PINN_USER + list(itertools.chain(*arguments.items()))
        logger.info("Adding a new user: running %r", args)
        subprocess.check_call(args)

    def delete_user(self, uid):
        raise NotImplementedError

        arguments = {}

        arguments['--delete'] = uid[0]

        args = ADD_PINN_USER + list(itertools.chain(*arguments.items()))
        logger.info("Deleting user, running %r", args)
        subprocess.check_call(args)

    def sync_user(self, ad_entry, user_entry):
        dn = user_entry['dn']
        del user_entry['dn']
        updated = user_entry.copy()

        if not 'remoteauthuser' in map(str.lower, user_entry['objectclass']):
            updated['objectclass'] = updated['objectclass'] + ['remoteauthuser']
            updated['remoteAuthDnAttr'] = [dn]
            updated['remoteauthDomainAttr'] = [self.config['handler']['domain']]

        if not 'provisioningmanagedentry' in map(str.lower, user_entry['objectclass']):
            updated['objectclass'] = updated['objectclass'] + ['provisioningmanagedentry']
            updated['provisioningId'] = [USER_ID]
            updated['provisioningLink'] = ad_entry['entryUUID']

        if 'mail' in ad_entry:
            updated['mail'] = ad_entry['mail']

        modlist = ldap.modlist.modifyModlist(user_entry, updated,
                                             ignore_oldexistent=True)
        if modlist:
            logger.info('Modifying user entry %r modlist: %s', dn, pretty_format(modlist))
            self.openldap_writer.modify_s(dn, modlist)

    def sync_group(self, ad_entry, group_entry):
        dn = group_entry['dn']
        del group_entry['dn']
        updated = group_entry.copy()

        if not 'provisioningmanagedentry' in map(str.lower, group_entry['objectclass']):
            updated['objectclass'] = updated['objectclass'] + ['provisioningmanagedentry']
            updated['provisioningId'] = [GROUP_ID]
            updated['provisioningLink'] = ad_entry['entryUUID']

        modlist = ldap.modlist.modifyModlist(group_entry, updated,
                                             ignore_oldexistent=True)
        if modlist:
            logger.info('Modifying group entry %r modlist: %s', dn, pretty_format(modlist))
            self.openldap_writer.modify_s(dn, modlist)

    def sync_entries(self, ad_entry, openldap_set):
        user = openldap_set.get(USER_ID)
        if not user:
            logger.error("No user entry in OpenLDAP %s", pretty_format(openldap_set))
            return
        self.sync_user(ad_entry, user)

        # all users share same primary group 1000, no sync needed
        return

        group = openldap_set.get(GROUP_ID)
        if not group:
            logger.error("No group entry in OpenLDAP %s", pretty_format(openldap_set))
            return
        self.sync_group(ad_entry, group)

    def run(self):
        self._start_ad_sync()
        self._start_openldap_sync()

        for ad_entry, openldap_set in ordered_zip(self._ad_entries(), self._openldap_entries()):
            logger.debug("Received %s", pretty_format((ad_entry, openldap_set)))

            if not openldap_set:
                uid = ad_entry.get('sAMAccountName')
                if not uid:
                    logger.error("Received user without sAMAccountName %s", pretty_format(ad_entry, verbosity=0))
                    continue

                if 'mail' not in ad_entry:
                    logger.warning("User %s has no email, skipping", uid[0])
                    continue

                self.add_user(uid, ad_entry)

                filterstr = filter_format("(uid=%s)", [uid[0]])
                results = self.openldap_writer.search_s(
                    self.config['connection']['base'], ldap.SCOPE_SUBTREE,
                    filterstr=filterstr)

                dn, attrs = results[0]
                user_entry = CIDict(attrs)
                user_entry['dn'] = dn

                # all users share same primary group
                #filterstr = filter_format("(&(cn=%s)(objectClass=posixGroup))", [uid[0]])
                #results = self.openldap_writer.search_s(
                #    self.config['connection']['base'], ldap.SCOPE_SUBTREE,
                #    filterstr=filterstr)

                group_entry = None
                #dn, attrs = results[0]
                #group_entry = CIDict(attrs)
                #group_entry['dn'] = dn

                openldap_set = CIDict({
                    USER_ID: user_entry, GROUP_ID: group_entry})
                logger.debug("Received openldap_set %s", pretty_format(openldap_set))

            if not ad_entry:
                uid = openldap_set.get(USER_ID, {}).get('uid')
                if not uid:
                    logger.error("User doesn't exist, but AD-linked data remains %s",
                                 pretty_format(openldap_set))
                    continue
                self.delete_user(uid)
            elif openldap_set:
                self.sync_entries(ad_entry, openldap_set)

        logger.info('Sync finished successfully')
        return 0

def main(args=None):
    "Main entry point"
    logging.basicConfig()

    options = parser.parse_args(args)

    global VERBOSITY
    VERBOSITY = options.verbose

    config = ConfigParser()
    if not config.read(options.config):
        logger.critical("Config file %r doesn't exist or is empty", options.config)
        return 1

    if sys.version_info.major == 2:
        config = CIDict({section: CIDict(dict(config.items(section))) for section in config.sections()})

    if 'logging' in config:
        logging.basicConfig()

        level = config['logging'].get('level')
        if level:
            level = level.upper()
            try:
                level = int(level)
            except ValueError:
                pass
            if level == 'DEBUG' or \
                    isinstance(level, type(logging.DEBUG)) and \
                        level > logging.NOTSET and level <= logging.DEBUG:
                VERBOSITY = -1

            logging.getLogger().setLevel(level)

        if sys.stderr.isatty():
            try:
                import coloredlogs
                coloredlogs.install(level=level)
            except ImportError:
                pass

    runner = SyncAD(config)
    return runner.run()

if __name__ == '__main__':
    rc = main(sys.argv[1:])
    sys.exit(rc)
