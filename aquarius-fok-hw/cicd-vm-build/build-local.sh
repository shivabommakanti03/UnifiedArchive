#!/bin/bash

BUILD_TIME=$(date -u +"%Y-%m-%d_%H-%M-%SZ")
GIT_HASH=$(git rev-parse --short HEAD &> /dev/null)
GIT_HASH_SLUG=${GIT_HASH:=nongit}
GIT_STATE=$([[ -n $(git rev-parse --is-inside-work-tree 2> /dev/null) && -z $(git status -s 2> /dev/null) ]] && echo "clean")
GIT_STATE_SLUG=${GIT_STATE:=dirty}
export BUILD_SLUG="platform-${BUILD_TIME}_${GIT_HASH_SLUG}_${GIT_STATE_SLUG}"
echo "BUILD_SLUG=${BUILD_SLUG}"
ansible-playbook build-vm-image-001-boot.yml $* || exit 1
ansible-playbook build-vm-image-002-install-steps.yml $* || exit 1
ansible-playbook build-vm-image-003-package.yml $* || exit 1
ansible-playbook build-vm-image-004-publish.yml $* || exit 1
