#!/usr/bin/env bash
sshpass -p root ssh -n -o StrictHostKeyChecking=no root@192.168.1.17 "$*"
