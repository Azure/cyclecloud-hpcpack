#!/usr/bin/env python

import http.client
import urllib
import json
import ssl

import logging
logger = logging.getLogger()


def create_ssl_context():
    ssl_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    ssl_context.options |= ssl.OP_NO_SSLv2 | ssl.OP_NO_SSLv3 | ssl.OP_NO_TLSv1 | ssl.OP_NO_TLSv1_1 | ssl.OP_NO_COMPRESSION
    return ssl_context


def get_auth_token():
    conn = http.client.HTTPConnection("169.254.169.254", timeout=2)
    headers = {'Metadata': True}
    params = {'api-version': '2018-02-01',
              'resource': 'https://vault.azure.net'}

    token_url = '/metadata/identity/oauth2/token?%s' % urllib.parse.urlencode(params)
    conn.request("GET", token_url, headers=headers)
    r = conn.getresponse()
    if r.status != 200:
        logger.error("Failed to fetch Identity Access Token (%s): %s (%s)" % (token_url, r.reason, r.status))
        raise Exception(r.reason)

    return json.loads(r.read())


def get_keyvault_secret(access_token, vault_name, secret_key):
    
    vault_address = '%s.vault.azure.net' % vault_name
    ssl_context = create_ssl_context()
    conn = http.client.HTTPSConnection(vault_address, context=ssl_context, timeout=15)
    

    
    headers = {'Authorization': 'Bearer %s' % access_token}
    params = {'api-version': '2016-10-01'}

    secret_url = '/secrets/%s?%s' % (secret_key, urllib.parse.urlencode(params))
    conn.request("GET", secret_url, headers=headers)
    r = conn.getresponse()
    if r.status != 200:
        logger.error("Failed to fetch Secret (%s): %s (%s)" % (secret_url, r.reason, r.status))
        raise Exception(r.reason)

    return json.loads(r.read())
    

def run():
    if len(sys.argv) < 3:
        logger.error("Usage: %s <vault name> <secret key>" % sys.argv[0])
        
    vault_name = sys.argv[1]
    secret_key = sys.argv[2]
    
    access_token_dict = get_auth_token()
    access_token = access_token_dict['access_token']

    secret_dict = get_keyvault_secret(access_token, vault_name, secret_key)
    
    # Output without newline so it may be assigned to script variables
    sys.stdout.write(secret_dict['value'].strip())

if __name__ == "__main__":
    import sys
    run()
