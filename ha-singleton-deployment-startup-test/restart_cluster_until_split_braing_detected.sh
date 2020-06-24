#!/bin/sh

home=$(dirname $0)

while $home/start_cluster.sh; do
    true
done


