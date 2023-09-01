#!/usr/bin/env python3
import os
import re
import sys
import semver
import subprocess

# Nexus API reqs + constants
import requests

### TODO 
# Need to detect dev -> master merge request build and not do shit.

### Expected tags:
#    master: 1.2.3                   - release
#       dev: 1.2.3-rc1               - dev release candidate
# during MR: 1.2.3-rc1-2-g2af9c732   - git auto version
#  after MR: 1.2.3.1-dev1+biomed1234 - add 4th digit
# commit MR: 1.2.3.1-dev2+biomed1234 - bump build
# other  MR: 1.2.3.2-dev1+devops1234 - bump 4th digit

###Flow
# dev == 10.2.20rc1
# 10.2.20rc1 -> branch == 10.2.20.1.dev1+foo
# 10.2.20rc1 -> branch == 10.2.20.2.dev1+bar
# --- work ---
# 10.2.20.2.dev1+bar commit == 10.2.20.2.dev2+bar
# 10.2.20.2.dev2+bar commit == 10.2.20.2.dev3+bar
# --- work ---
# 10.2.20.2.dev3+bar -> dev == 10.2.21.rc1
# 10.2.20.1.dev1+foo -> dev == 10.2.22.rc1

# If two feature branches are cut from say 10.2.20rc1 then we need to ensure
# they don't end up with the same pico version, i.e. 10.2.20.1
# We will need to query the Nexus API to find the latest version along that line
# and go from there.

### Needed for testing
# export CI_PIPELINE_SOURCE=merge_request_event
# export CI_COMMIT_REF_NAME=DEVOPS-1234
# export CI_MERGE_REQUEST_LABELS=major,something
# export CI_REPOSITORY_URL=something

### Expected flow:
# MR to dev will produce a version like 2.1.6-rc1-1-g75f461d
# The -1-g75f461d is added automatically to the end by git on a commit.
# The -1 represents 1 commit away from tag "2.1.6-rc1"
# The -g75f461d is the short SHA of that commit


def git(*args):
    return subprocess.check_output(["git"] + list(args))


def next_pico_version(dev_version):
    # Expects to get a 3 digit version, it will give the next availble
    # pico version - next_pico_version('14.2.1') will return 1 if there are no
    # other 14.2.1.x versions. If there are, it will return the next available number

    api_url = 'https://nexus.text2phenotype.com/service/rest/v1/search/assets?repository=pypi-lifesciences&name=text2phenotype'
    match_versions = set()
    picoVer = 1
    token = ''
    url = api_url
    version_set = set()

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

    # Find all possible versions for target
    for ver in version_set:
        if dev_version in ver:
            # Found version matching our target 3 digit version
            print('Found:',ver)
            semver = (re.search('^\d+\.\d+\.\d+\.?\d?', ver).group()).rstrip('.')
            match_versions.add(semver)

    for match in match_versions:
        if re.search('^\d+\.\d+\.\d+\.\d+', match):
            # 4 digit version exist, we need to return 1 higher
            pv = int(match.split('.')[3])
            while picoVer < pv+1:
                picoVer+=1
    return str(picoVer)


def tag_repo(tag):
    try:
        if os.environ["CI"] == 'true':
            tagEnabled = True
    except KeyError:
            tagEnabled = False

    if tagEnabled:
        print("Tagging repo...")
        url = os.environ["CI_REPOSITORY_URL"]

        # Transforms the repository URL to the SSH URL
        # Example input: https://gitlab-ci-token:xxxxxxxxxxxxxxxxxxxx@gitlab.com/threedotslabs/ci-examples.git
        # Example output: git@gitlab.com:threedotslabs/ci-examples.git

        push_url = re.sub(r'.+@([^/]+)/', r'git@\1:', url)
        print(push_url)
        git("remote", "set-url", "--push", "origin", push_url)
        git("tag", tag)
        git("push", "origin", tag)
    else:
        # We are not running on the CI server
        print("Not on CI server, would have tagged repo with: " + tag)

# Check if a tag already exists
def tag_exists(tag):
    if subprocess.run(["git", "rev-parse", tag], \
      stdout=subprocess.DEVNULL, \
      stderr=subprocess.DEVNULL).returncode != 0:
        # Tag does not exist yet
        return False
    else:
        return True

def bumpit(ver, bumpOperation):
    if bumpOperation == 'MAJOR':
        return semver.bump_major(ver)
    elif bumpOperation == 'MINOR':
        return semver.bump_minor(ver)
    else:
        return semver.bump_patch(ver)

def bump(rawGitTag, branch, bumpOperation):
    if re.search('^\d+\.\d+\.\d+\.\d+', rawGitTag):
        #This is a 4 digit version - we will have to fake a semver through this process
        # Versions like 2.1.23.1-dev1+devops1234-1-g8e51be0
        longSemVer = rawGitTag.split('-')[0]
        remainingTag = rawGitTag.split('-')[1]
        picoVerNum = re.search('\d$', longSemVer).group()
        semVer = re.match('^\d+\.\d+\.\d+', longSemVer).group()
        versionObj = semver.VersionInfo.parse(semVer + '-' + remainingTag)

    else:
        # The tag is the auto generated one like 14.0.0-1-g501e7517
        versionObj = semver.VersionInfo.parse(rawGitTag)
        longSemVer = None
        picoVerNum = None
        semVer = str(versionObj.major) + '.' + str(versionObj.minor) + '.' + str(versionObj.patch)

    print('##########')
    print('Major: ' + str(versionObj.major))
    print('Minor: ' + str(versionObj.minor))
    print('Patch: ' + str(versionObj.patch))
    if picoVerNum:
        print('Pico : ' + picoVerNum)
    print('Pre  : ' + str(versionObj.prerelease))
    print('Build: ' + str(versionObj.build))
    print('##########')

    # On an MR's first run, the tag will have rc in it: 2.1.6-rc1-1-g75f461d
    # Subsequent runs will have dev in the name: 2.1.7-dev1-1-ge45f9c8
    # We don't bump any versions on MRs, we add new prerelease versions and will bump those:
    # 1.2.3-dev1+biomed1234 -> 1.2.3-dev2+biomed1234 on each push to an MR.

    if branch == 'dev':
        # This is a push to dev
        # Replace dev with the current branch.1
        versionObj = versionObj.replace(prerelease = 'rc0')
    elif versionObj.prerelease.startswith('rc'):
        # This is the first run of an MR where the tag is still from dev (rc) but in a branch
        versionObj = versionObj.replace(prerelease = 'dev0')
        # This will be determined by the first available version in the package repo
        picoVerNum = next_pico_version(semVer)
    else:
        # Multiple runs on an MR that's been tagged with the branch already where we keep the version number
        # Normalize prerelease by removing -1-g75f461d but keeping devops1234.1
        versionObj = versionObj.replace(prerelease = re.match('.*\d+$', versionObj.prerelease).group() )

    # print('Semver: ' + semVer)
    # print('VersionID: ' + str(versionObj))

    if branch == 'master':
        # 1.2.3
        # Have to deal with a master duplicate tag as it doesn't normally get bumped
        while tag_exists(semVer):
            semVer = bumpit(semVer, bumpOperation)
        return semVer
    elif branch == 'dev':
        # 1.2.3_dev1
        return (bumpit(semVer, bumpOperation) + '-rc1')
    else:
        # 2.1.5-dev1-1-g9b1aca4
        # if bumpOperation != "PATCH":
        # We have a prerelease with a 1 at the end, need to bump
        versionObj = versionObj.bump_prerelease()
        versionObj = versionObj.replace( build = branch )
        # Reconstruct our long version
        tempVer = (str(versionObj).split('-')[0]) + '.' + picoVerNum
        return tempVer + '-' + str(versionObj.prerelease) + '+' + str(versionObj.build)

def main():
    print ('>> Starting auto version script...')
    ciPiplineSource = os.environ["CI_PIPELINE_SOURCE"]
    ### Merge requests and pushes have different variables
    try:
        # This is present on both push and MR
        envBranch = os.environ["CI_COMMIT_REF_NAME"]
        branch = (envBranch.replace('-', '')).lower()
        # shortSHA = os.environ["CI_COMMIT_SHORT_SHA"]
    except KeyError:
        print('Unknown condition, CI_COMMIT_REF_NAME not present')
        sys.exit(1)

      ### Check if we are going to bump minor/major
    try:
        ciMergeRequestLabels = [ x.upper() for x in (os.environ["CI_MERGE_REQUEST_LABELS"].split(','))]
    except KeyError:
        ciMergeRequestLabels = ["None"]


    if 'MAJOR' in ciMergeRequestLabels:
        bumpOperation = 'MAJOR'
    elif 'MINOR' in ciMergeRequestLabels:
        bumpOperation = 'MINOR'
    else:
        bumpOperation = 'PATCH'

    print('Bump operation:', bumpOperation)
    print('Working branch:', branch)

    # This is present via a push
    try:
        envCommitBranch = os.environ["CI_COMMIT_BRANCH"]
    except KeyError:
        envCommitBranch = 'none'

    print('Commit branch :', envCommitBranch)

    try:
        rawGitTag = git("describe", "--tags").decode().strip()
        print('Current tag   :', rawGitTag)
    except subprocess.CalledProcessError:
        # No tags in the repository
        version = "1.0.0"
        tag_repo(version)
    else:
        # This is a merge request with a source of not dev/master
        if ciPiplineSource == 'merge_request_event' and (branch != 'master' and branch != 'dev'):
            version = bump(rawGitTag, branch, bumpOperation)
            print('>>> New tag =', version, "<<<")
            tag_repo(version)

        # This is push typically when a MR is accepted and we are pushing to dev/master
        elif ciPiplineSource == 'push':

            # Test if on dev/master that version does not already exist (out of date branch being merged to dev/master)
            attempts=0
            print("Checking tag: ", rawGitTag)
            while tag_exists(rawGitTag) and attempts < 10:
                # That tag exists, lets try and bump it again and again
                print("Tag ", rawGitTag, " exists, bumping...")
                rawGitTag = version = bump(rawGitTag, branch, bumpOperation)
                print("Bumped tag: ", rawGitTag)
                attempts += 1

            # Tag does not exist, lets tag it
            print('New tag    =', version)
            tag_repo(version)
        else:
            print('Source branch ' + branch + ', not bumping version during MR to dev/master')

    return 0

if __name__ == "__main__":
    sys.exit(main())
