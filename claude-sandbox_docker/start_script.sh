#!/usr/bin/env bash

# Start the postfix service for mail notifications:
service postfix start

# Start the docker service so we can run docker in a docker for tests:
~/start_dockerd.sh

claude

