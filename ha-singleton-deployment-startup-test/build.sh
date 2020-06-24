#!/bin/sh

home=$(dirname $(readlink -f $0))

(cd $home/../ha-singleton-deployment && mvn clean install -Denforcer.skip=true -Dcheckstyle.skip=true)

