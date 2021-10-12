#!/bin/bash

# READ FIRST BEFORE USING THIS SCRIPT
#
# This script expects directory structure described in:
# https://github.com/openshift/kubernetes/blob/master/REBASE.openshift.md#preparing-the-local-repo-clone

set -ux

# validate input args --k8s-tag=v1.21.2 --openshift-release=release-4.8 --bugzilla-id=2003027
k8s_tag=""
openshift_release=""
bugzilla_id=""

usage() {
    echo "Available arguments:"
    echo "  --k8s-tag            (required) Example: --k8s-tag=v1.21.2"
    echo "  --openshift-release  (required) Example: --openshift-release=release-4.8"
    echo '  --bugzilla-id        (optional) creates new PR against openshift/kubernetes:${openshift-release}: Example: --bugzilla-id=2003027'
}

for i in "$@"; do
  case $i in
    --k8s-tag=*)
      k8s_tag="${i#*=}"
      shift
      ;;
    --openshift-release=*)
      openshift_release="${i#*=}"
      shift
      ;;
    --bugzilla-id=*)
      bugzilla_id="${i#*=}"
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ -z "${k8s_tag}" ]; then
    echo "Required argument missing: --k8s-tag"
    echo ""
    usage
    exit 1
fi

if [ -z "${openshift_release}" ]; then
    echo "Required argument missing: --openshift-release"
    echo ""
    usage
    exit 1
fi

echo "Processed arguments are:"
echo "--k8s_tag=${k8s_tag}"
echo "--openshift_release=${openshift_release}"
echo "--bugzilla_id=${bugzilla_id}"

# prerequisites (check git, podman, ... is present)
if ! command -v git &> /dev/null
then
    echo "git not installed, exiting"
    exit 1
fi

if ! command -v podman &> /dev/null
then
    echo "podman not installed, exiting"
    exit 1
fi

# make sure we're in "kubernetes" dir
current_dir=$(basename $PWD)
if [[ $current_dir != "kubernetes" ]]; then
    echo "Not in kubernetes dir, exiting"
    exit 1
fi

# fetch remote https://github.com/kubernetes/kubernetes
git fetch upstream --tags
# fetch remote https://github.com/openshift/kubernetes
git fetch openshift

git checkout openshift/"$openshift_release"
git pull openshift "$openshift_release"

git merge $k8s_tag

if [ $? -eq 0 ]; then
    echo "No conflicts detected. Automatic merge looks to have succeeded"
else
    # commit conflicts
    git commit -a
    # resolve conflicts
    git status
    echo "Resolve conflicts manually, then continue"

    # wait for user interaction
    read -n 1 -s -r -p "PRESS ANY KEY TO CONTINUE: "

    git commit -am "UPSTREAM: <drop>: manually resolve conflicts"
fi

# update dependencies
sed -E "/=>/! s/(\tgithub.com\/openshift\/[a-z|-]+) (.*)$/\1 $openshift_release/" go.mod
go mod tidy
hack/update-vendor.sh

# figure out which image should be used
# skopeo list-tags docker://registry.ci.openshift.org/openshift/release
# openshift-hack/images/hyperkube/Dockerfile.rhel still has FROM pointing to old tag
sed -E "s/(io.openshift.build.versions=\"kubernetes=)(1.[1-9]+.[1-9]+)/\1$k8s_tag/" openshift-hack/images/hyperkube/Dockerfile.rhel
go_mod_go_ver=$(grep -E 'go 1\.[1-9][0-9]?' go.mod | sed -E 's/go (1\.[1-9][0-9]?)/\1/')
tag="rhel-8-release-golang-${go_mod_go_ver}-openshift-${openshift_release#release-}"

podman run -it --rm -v $( pwd ):/go/k8s.io/kubernetes:Z \
    --workdir=/go/k8s.io/kubernetes \
    registry.ci.openshift.org/openshift/release:$tag \
    make update OS_RUN_WITHOUT_DOCKER=yes

git add -A
git commit -m "UPSTREAM: <drop>: hack/update-vendor.sh, make update and update image"

remote_branch="rebase-$k8s_tag"
git push origin "$openshift_release":$remote_branch

XY=$(echo $k8s_tag | sed -E "s/v(1\.[0-9]+)\.[0-9]+/\1/")
ver=$(echo $k8s_tag | sed "s/\.//g")
link="https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$XY.md#$ver"
echo $link
if [ -n "${bugzilla_id}" ]
then
if command -v gh &> /dev/null
then
    XY=$(echo $k8s_tag | sed -E "s/v(1\.[0-9]+)\.[0-9]+/\1/")
    ver=$(echo $k8s_tag | sed "s/\.//g")
    link="https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$XY.md#$ver"
    gh pr create \
        --title "Bug $bugzilla_id: Rebase $k8s_tag" \
        --body "CHANGELOG $link"
fi
fi
