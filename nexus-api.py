#!/usr/bin/env python3

import requests
import re
from distutils.version import LooseVersion

dev_version='14.1.38'

# api_url = 'https://nexus.text2phenotype.com/service/rest/v1/assets?repository=pypi-lifesciences'
api_url = 'https://nexus.text2phenotype.com/service/rest/v1/search/assets?repository=pypi-lifesciences&name=text2phenotype'

token = ''
match_versions = set()
url = api_url
version_set = set()
picoVer = 1

# temp
version_set.add('14.1.38.1.dev5+bs')
version_set.add('14.1.38.3.dev5+bs')

print("Querying Nexus for text2phenotype package versions", end='')

while token is not None:
  print('.', end='', flush=True)

  resp = requests.get(url)
  resp_j = resp.json()

  for item in resp_j['items']:
    version_set.add(item['pypi']['version'])

  token = resp_j['continuationToken']
  if token is not None:
    url = api_url + '&continuationToken=' + token

print(' Done!')
print('Devver',dev_version)

# Find all possible versions for target
for ver in version_set:
  if dev_version in ver:
    # Found version matching our target 3 digit version
    print('Found:',ver)
    semver = (re.search('^\d+\.\d+\.\d+\.?\d?', ver).group()).rstrip('.')
    match_versions.add(semver)

for match in match_versions:
  if re.search('^\d+\.\d+\.\d+\.\d+', match):
  # If 4 digit version
    pv = int(match.split('.')[3])
    while picoVer < pv+1:
      picoVer+=1

print('pico',picoVer)

  # Should have just the verison, either 3 or 4 digit
  # if re.search('^\d+\.\d+\.\d+\.\d+', ver):
  #   # Found 4 digit version
  #   pv = int(ver.split('.')[3])
  #   while picoVer < pv+1:
  #     picoVer+=1
  #   print('pico',picoVer)
