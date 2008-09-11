#! /bin/bash
export BUILDER_VERSION="[[ver]]"
exec "$(dirname "$0")/builder/runbuilder" -U
