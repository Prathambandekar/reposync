#!/bin/bash
df -Th | awk '{ print $1,$2, $6 }' | grep xfs
