#!/usr/bin/env zsh

set -o pipefail
set -e

###
# This script will attempt to upgrade text2phenotype-py across all services
# that rely on it it. It will create a merge request with the latest version
# of text2phenotype-py included in the requirements.txt file.

### Script goals - other
# step 1: set up the MRs
# step 2: test dev_latest
# step 3: merge to master
# - Wiat for text2phenotype-py build to finish?
# step 4: deploy latest & test
# step 5: deploy release

### By default this script will:
# Checkout the dev branch and pull
# Create a new RELEASE branch
# Update the requirements.in file with the latest text2phenotype RC (dev branch) package version
# Run pip-compile to create an updated requirements.txt file
# Create a commit capturing all of this and push it to origin(Gitlab)
# Create a merge request for the current repo
# After doing all repos it will print out a list of the MRs created
###

### Usage: releaser.sh <targetBranch> [operation]
# The default is to update the text2phenotype package in all repos and create
#   an MR to publish these changes.
# If master is passed, only an MR from dev -> master will be created
# If dev is passed, only an MR from master -> dev will be created
# If dev & merge is passed, then it will merge all the dev -> master MRs

### User editable values
REPO_DIR=${REPO_DIR:-$HOME/repos}
# REPO_DIR=${REPO_DIR:-$HOME/tmp/repos}

### Global Vars
API_URL="https://git.text2phenotype.com/api/v4"
DESC=''
MODE=''
R_BRANCH='RELEASE'
REPOS=( biomed ctakes discharge FDL feature-service intake text2phenotype-api text2phenotype-py text2phenotype-tasks mips sands )
# REPOS=( builderbot )
# These repos will not have a pip-compile run on them, but will get MRs to and from master & dev
NO_PACKAGE_REPOS=( ctakes text2phenotype-py FDL )
S_BRANCH='NULL'
T_BRANCH='NULL'
TITLE=''
TOKEN=${TOKEN:-NULL}
TMP_SEED=$(date +%s)
VERSION=''

# Arrays
declare -a MR_LIST

### Pre-flight
#
#
if [[ $TOKEN == 'NULL' ]]; then
  echo "Please 'export TOKEN=<your token>' with your personal access token:"
  echo "https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html"
  exit 1
fi

for cmd in pip-compile git curl grep ; do 
  if ! which $cmd &> /dev/null; then
    echo "$cmd is required, please install it."
    exit 1
  fi
done

if [[ ! -d $REPO_DIR ]]; then
  echo "$REPO_DIR does not exist, please export REPO_DIR to the proper directory where local repos exist"
  exit 1
fi

### functions
#
#
_get_padding() {
  # Expects an array
  # Returns length of longest string + 2
  local strings=("$@")
  local max_len=0

  for string in "${strings[@]}"; do
    len=$(echo -n "${string}xx"|wc -c)
    if [[ $max_len -lt $len ]]; then
      max_len=$len
    fi
  done
  printf $max_len
}

get-project-id() {
  # Docs: https://docs.gitlab.com/ee/api/projects.html
  local project="$1"
  local api_request="$API_URL/projects/data-management%2Fnlp%2F${project}"
  local resp=$( \
    curl -s -X GET \
    --data-urlencode "private_token=$TOKEN" \
    --data-urlencode "simple=true" \
    $api_request \
  )
  echo "$resp" | jq -r '.id'
}

create-mr() {
  # Args: <ProjectName> <sourceBranch> <targetBranch> <"title"> <"description">
  # Title & description must be quoted if they have spaces
  # Docs: https://docs.gitlab.com/ee/api/merge_requests.html

  local p_id="$(get-project-id $1)"
  local s_br="$2"
  local t_br="$3"
  local title="$4"
  local desc="$5"
  local api_request="$API_URL/projects/$p_id/merge_requests"

  echo "Creating MR for $1..."

  # Set addiotional options based on what we are doing...
  if [[ "$s_br" == "master" || "$t_br" == "dev" ]]; then
    local extra_options=( --data-urlencode labels=POSTRELEASE )
  elif [[ "$s_br" == "dev" && "$t_br" == "master" ]]; then
    local extra_options=( --data-urlencode labels=RELEASE )
  else
    local extra_options=( --data-urlencode remove_source_branch=true )
  fi

  local response=$( \
    curl -s -X POST \
    --data-urlencode "id=$p_id" \
    --data-urlencode "source_branch=$s_br" \
    --data-urlencode "target_branch=$t_br" \
    --data-urlencode "title=$title" \
    --data-urlencode "description=$desc" \
    --data-urlencode "private_token=$TOKEN" \
    ${extra_options[@]} \
    "$api_request" \
  )

  local web_url=$(echo "$response" | jq -r '.web_url')
  if [[ $web_url =~ "https" ]]; then
    MR_LIST+=( "$1: $web_url" )
  else
    echo "An error has occured, dumping response:"
    echo "$response" | jq .
  fi
}

get-open-mr-id() {
  # Args: <ProjectName> <Release name>
  local p_id="$(get-project-id $1)"
  local release="$2"
  local api_request="$API_URL/projects/$p_id/merge_requests/?state=opened"

  local response=$( \
    curl -s -X GET \
    --data-urlencode "id=$p_id" \
    --data-urlencode "search=$release" \
    --data-urlencode "private_token=$TOKEN" \
    "$api_request" \
  )

  local iid=$(echo "$response" | jq -r '.[].iid')
  # If this doesn't come up with a number, then the request failed, dump the response
  if [[ "$iid" =~ [0-9] ]]; then
    echo -n "$iid"
  else
    echo "An error occured trying to find $1 MR, dumping response..."
    echo "$response"
  fi
}

merge-mr() {
  # Args: <ProjectName> <MR-ID>
  # MR-ID is the MR ID that is visable with a ! in front of it
  local p_id="$(get-project-id $1)"
  local mr_id="$2"
  local api_request="$API_URL/projects/$p_id/merge_requests/$mr_id/merge"

  local response=$( \
    curl -s -X PUT \
    --data-urlencode "id=$p_id" \
    --data-urlencode "merge_request_iid=$mr_id" \
    --data-urlencode "private_token=$TOKEN" \
    "$api_request" \
  )

  local mr_status=$(echo "$response" | jq -r '.merge_error')
  if [[ $mr_status != "null" ]]; then
    echo "An error occured trying to merge the $1 MR ${mr_id}, dumping response..."
    echo "$response" | jq .
  fi
}

get-lastest-text2phenotype-verison() {
  # This will query the Nexus server and return the latest version available
  # or the specific release (rc, dev, or final[default])
  local nexus_url="https://nexus.text2phenotype.com/repository/pypi-lifesciences/simple/text2phenotype"
  local rel=${1:-'rc'}

  if [[ "$rel" == 'final' ]]; then
    local filter="egrep -v rc|dev"
  else
    local filter=( grep $rel )
  fi

  local ver=$(curl -s $nexus_url | \
    egrep -o 'text2phenotype/[[:alnum:]|\.]+' | \
    cut -d '/' -f2 | \
    sort -uV | \
    ${filter[@]} | \
    tail -1 \
  )

  if [[ -n $ver ]]; then
    echo -n "$ver"
  else
    return 1
  fi
}

upgrade-text2phenotype() {
  local ver="${1:-$(get-lastest-text2phenotype-verison)}"
  local file=${2:-requirements.in}

  echo "Updating $file with latest text2phenotype version: $ver"
  sed -i "s/^text2phenotype.*/medal==$ver/" "$file"
}

create-release-branch() {
  echo "Creating release branch..."
  if git rev-parse --verify $R_BRANCH; then
    echo "$R_BRANCH exists, deleting..."
    git branch -D $R_BRANCH
    git push origin --delete $R_BRANCH || true
  fi
  git checkout -t -b $R_BRANCH
}

wait-for-key() {
  if [[ ! $WAITED ]]; then
    echo "** Press any key to continue **"
    read -sk1
  fi
  WAITED=true
}

get-release-and-ticket-numbers() {
  local skip="$1"
  local ticket

  # Get title for all MRs
  echo -ne "Release version ex: v16.0.00\nVersion: "
  read VERSION
  TITLE="$VERSION Release"

  if [[ -z $skip ]]; then
    # We only want the number of the ticket 123, not DEPLOYMENT-123
    until [[ "$ticket" =~ [0-9] && ! "$ticket" =~ [a-zA-Z] ]]; do
      echo -ne "Ticket NUMBER for description ex: 123\nTicketNum: "
      read ticket
    done
    DESC="https://jira.text2phenotype.com/browse/DEPLOYMENT-$ticket"
  fi
}

compile-requirements-test() {
  local ver="${1:-$(get-lastest-medal-verison)}"

  req_files=( requirements-test.in requirements_dev.in )
  for req_file in ${req_files[@]}; do
    if [[ -a $req_file ]]; then
      echo "Found requirements test file, compiling..."
      pip-compile --pre --upgrade-package medal "$req_file" 2>&1 | egrep '^medal'
    fi
  done
}

tag-master-release() {
  # Args: < Repo name > < tag >
  # Tag master on repo with given tag
  local repo="$1"
  local tag=$( echo "$2" | tr -d 'v' ) # Remove v from Release
  local previous_branch=$( git rev-parse --abbrev-ref HEAD )

  pushd $REPO_DIR/$repo &> /dev/null
  if git checkout --quiet master; then
    git pull --quiet --recurse-submodules
  else
    echo "Unable to checkout master on $repo"
    echo "On branch: $(git rev-parse --abbrev-ref HEAD)"
    popd &> /dev/null
    return 1
  fi

  # Make sure it doesn't exist already
  if ! git show-ref "$tag" --quiet; then
    echo "Tagging $repo master branch with ${tag}..."
    git tag "$tag"
    git push origin "$tag"
  else
    echo "$tag exists for $repo, skipping..."
  fi
  git checkout --quiet "$previous_branch"
  popd &> /dev/null
}

select-mode() {
  local ops=( \
  'Dev -> master MR' \
  'Master -> Dev MR' \
  'Update Medal package' \
  'Merge Dev -> Master MRs' \
  'Merge Master -> Dev MRs' \
  'Tag master with Release' \
  )

  select op in ${ops[@]}; do
    case $REPLY in
      1)
        echo "Creating an MR for all repos from dev -> master"
        get-release-and-ticket-numbers
        wait-for-key
        MODE="dev-master-mr"
        S_BRANCH='dev'
        T_BRANCH='master'
      ;;
      2)
        echo "Creating an MR for all repos from master -> dev"
        get-release-and-ticket-numbers skip
        wait-for-key
        MODE="master-dev-mr"
        S_BRANCH='master'
        T_BRANCH='dev'
      ;;
      3)
        ### This will upgrade the medal package in the repo
        # and create an MR to push the changes with the updated requirements.in/txt
        echo "Updating medal package & creating an MR with those changes..."
        get-release-and-ticket-numbers
        wait-for-key
        MODE="update-medal-package"
      ;;
      4)
        ### This will merge all the MRs from Dev -> Master for a given release.
        echo "Merging all MRs from dev -> master for a release"
        get-release-and-ticket-numbers skip
        wait-for-key
        MODE="merge-dev-master-mr"
        T_BRANCH='master'
      ;;
      5)
        ### This will merge all the MRs from Master -> Dev for a given release.
        echo "Merging all MRs from dev -> master for a release"
        get-release-and-ticket-numbers skip
        wait-for-key
        MODE="merge-master-dev-mr"
        T_BRANCH='dev'
      ;;
      6)
        ### This will tag all master releases with the given version number
        # i.e. 16.2.00 etc.
        echo "Tagging all current master branches with release number..."
        get-release-and-ticket-numbers skip
        wait-for-key
        MODE="tag-master-release"
      ;;
    esac
    break
  done
}

### Main
#
#

select-mode

for repo_name in ${REPOS[@]}; do
  repo="$REPO_DIR/$repo_name"
  if [[ ! -d $repo ]]; then
    echo -e "Missing $repo_name repo, cannot continue\nDir: $repo"
    exit 1
  fi

  if [[ "$MODE" == "dev-master-mr" ]]; then
    create-mr $repo_name $S_BRANCH $T_BRANCH "$TITLE" "$DESC"

  elif [[ "$MODE" == "master-dev-mr" ]]; then
    TMP_TITLE="Merge branch 'master' into 'dev' - $VERSION"
    create-mr $repo_name $S_BRANCH $T_BRANCH "$TMP_TITLE" "$TITLE"

  elif [[ "$MODE" == "merge-dev-master-mr" ]]; then
    merge_id=$(get-open-mr-id "$repo_name" "$VERSION")
    if [[ $merge_id =~ [0-9]+ ]]; then
      merge-mr "$repo_name" "$merge_id"
      tag-master-release "$repo_name" "$VERSION"
    else
      echo "No merge ID found for $repo_name, skipping merge..."
    fi

  elif [[ "$MODE" == "merge-master-dev-mr" ]]; then
    merge_id=$(get-open-mr-id "$repo_name" "$VERSION")
    if [[ $merge_id =~ [0-9]+ ]]; then
      merge-mr "$repo_name" "$merge_id"
    else
      echo "No merge ID found for $repo_name, skipping merge..."
    fi

  elif [[ "$MODE" == "tag-master-release" ]]; then
    tag-master-release "$repo_name" "$VERSION"

  elif [[ "$MODE" == "update-medal-package" ]]; then
    # Skip this repo as it's not dependent on medal package
    if [[ ${NO_PACKAGE_REPOS[@]} =~ "$repo_name" ]]; then
      echo "Skipping medal package upgrade for repo: $repo_name"
      continue
    fi

    # Upgrade requirements.in, pip-compile, and create MR with those changes
    COMPILE_OPTIONS=( '--pre' )

    echo "Pulling $S_BRANCH in ${repo_name}..."
    pushd $repo &> /dev/null
    if git checkout --quiet $S_BRANCH; then
      git pull --quiet --recurse-submodules
      create-release-branch
      upgrade-medal
      echo "Running pip-compile..."
      export PIP_CONFIG_FILE="$repo/bin/pip.conf"
      cp requirements.txt requirements.txt.${TMP_SEED}
      pip-compile --upgrade-package medal ${COMPILE_OPTIONS[@]} 2>&1 | egrep '^medal'
      compile-requirements-test
      diff requirements.txt requirements.txt.${TMP_SEED} || true
      rm requirements.txt.${TMP_SEED}
      git add "requirements*"
      git checkoutmmit -m "Release: $VERSION"
      git push --set-upstream origin
      create-mr $repo_name $R_BRANCH $S_BRANCH "$TITLE" "$DESC"
      popd &> /dev/null
    else
      echo "Unable to checkout $S_BRANCH in $repo_name"
      exit 1
    fi
  fi
done

if [[ ${#MR_LIST[@]} -gt 0 ]]; then
  # Add convenient link to the bottom
  all_url='https://git.text2phenotype.com/groups/data-management/nlp/-/merge_requests?label_name[]=RELEASE&label_name[]=POSTRELEASE'
  MR_LIST+=( "ALL: $all_url" )
  # Get padding for output
  pad=$(_get_padding "${REPOS[@]}")

  # Print out list of merge requests created
  echo -e "\n\nMerge requests created:"
  for mr_line in "${MR_LIST[@]}"; do
    name=$( echo "$mr_line" | cut -d ':' -f1 )
    url=$( echo "$mr_line" | cut -d ' ' -f2 )
    printf "%-${pad}s : %s\n" $name $url
  done
fi
