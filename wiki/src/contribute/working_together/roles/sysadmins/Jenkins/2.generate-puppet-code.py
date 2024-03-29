#!/usr/bin/python3
#
# Read a list of plugins with versions and dependencies and produce Puppet
# code good for use in the `tails::jenkins::master` class.
#
# This script does some ugly HTML parsing to grab the hash of the latest plugin
# binary available from the Jenkins updates website.
#
# Input is one line per plugin, each with the following format:
#
#     name version [comma-separated list of dependencies]

import argparse
import fileinput
import re
import requests

from bs4 import BeautifulSoup


BASE_URL = 'https://updates.jenkins.io/download/plugins'


def fetch_hash(plugin):
    url = BASE_URL + '/' + plugin
    page = requests.get(url)
    soup = BeautifulSoup(page.text, 'html.parser')
    # This has to be updated when/if the Jenkins update website HTML changes
    h = next(filter(lambda e: 'SHA-256' in e.text, soup.findAll('div', {'class':'checksums'}))).findChildren('code')[0].text
    return h


def parse_plugins(path):
    with open(path) as f:
        lines = f.readlines()
    plugins = {}
    for l in lines:
        plugin, version, rawdeps = l.split(' ', maxsplit=2)
        plugins[plugin] = version
        rawdeplist = rawdeps.strip('[]\n').split(' ')
        deps = []
        for rawdep in rawdeplist:
            depname = rawdep.rstrip(',')
            if (depname):
                deps.append(depname)
        plugins[plugin] = {'version': version, 'deps': deps}
    return plugins


def print_puppet_code(plugin, version, deps):
    h = fetch_hash(plugin)
    print('  jenkins::plugin { \'' + plugin + '\':')
    print('    version       => \'' + version + '\',')
    print('    digest_string => \'' + h + '\',')
    print('    digest_type   => \'sha256\',')
    if deps:
        print('    require       => Jenkins::Plugin[')
        for dep in deps:
            print('      \'' + dep + '\',')
        print('    ],')
    print('  }')
    print('')


def main(path):
    plugins = parse_plugins(path)
    for plugin, data in plugins.items():
      print_puppet_code(plugin, data['version'], data['deps'])


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('file', help='The input file, as generated by the Groovy script')
    args = p.parse_args()
    main(args.file)
