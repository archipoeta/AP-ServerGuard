#!/bin/sh

##
#	Title: AP-ServerGuard - Installer
#	Desc: Installer for AP-ServerGuard
#	Author: Archpoet
#	Email: archipoetae@gmail.com
#	Date: 2015.05.20
##

APP_DIR=`pwd`

INIT_PATH=$1
BIN_PATH=$2

# Set Defaults
if [ -z "$INIT_PATH" ]; then
	INIT_PATH="/etc/init.d"
fi

if [ -z "$BIN_PATH" ]; then
	BIN_PATH="/usr/local/bin"
	if [ ! -d "$BIN_PATH" ]; then
		BIN_PATH="/usr/bin"
	fi
fi

# Link Daemon and Bin
ln -s $APP_DIR/ap_serverguard.init $INIT_PATH/ap_serverguard
ln -s $APP_DIR/ap_serverguard.pl $BIN_PATH/ap_serverguard
