SET	app_name	YourSway Builder

# FILE	CocoaDialog.zip	-	CocoaDialog.zip	megabox-eclipses
# NEWDIR	CocoaDialog.app	temp	CocoaDialog.app	-

REPOS	builder	-	YourSway Builder
	GIT	origin	-	git://github.com/andreyvit/yoursway-builder.git
REPOS	create-dmg	-	create-dmg
	GIT	andreyvit	-	git://github.com/andreyvit/yoursway-create-dmg.git

VERSION	builder.cur	builder	heads/master
VERSION	create-dmg.cur	create-dmg	heads/master

NEWDIR	build.dir	temp	%-build	-
NEWDIR	temp2	temp	%.tmp	-

NEWDIR	builder.app	temp	%.app	% application bundle
NEWFILE	builder.dmg	featured	%.dmg	% for Mac OS X


##############################################################################################################
# Mac application
##############################################################################################################

# UNZIP	[CocoaDialog.zip]	[CocoaDialog.app]
# 	INTO	/	CocoaDialog.app

COPYTO	[temp2]
	INTO	ysbuilder-mac.sh	[builder.cur]/builds/ysbuilder-mac.sh
	
SUBSTVARS	[temp2<alter>]/ysbuilder-mac.sh	[[]]

COPYTO	[build.dir]
	INTO	builder	[builder.cur]

INVOKE	platypus
	ARGS	-P	[builder.cur]/builds/ysbuilder.platypus
	ARGS	-FD
	ARGS	-R
	ARGS	-a	YourSway Builder
	ARGS	-p	/bin/bash
	ARGS	-V	[ver]
	ARGS	-f	[build.dir]/builder
	ARGS	-I	com.yoursway.Builder
	ARGS	-c	[temp2]/ysbuilder-mac.sh
	ARGS	[builder.app]


##############################################################################################################
# Mac DMG
##############################################################################################################

NEWDIR	dmg_temp_dir	temp	%-dmg.tmp	-

COPYTO	[dmg_temp_dir]
	SYMLINK	Applications	/Applications
	INTO	[app_name].app	[builder.app]

INVOKE	[create-dmg.cur]/create-dmg
	ARGS	--window-size	500	310
	ARGS	--icon-size	96
	ARGS	--background	[builder.cur]/builds/background.gif
	ARGS	--volname	YourSway Builder [ver]
	ARGS	--icon	Applications	380	205
	ARGS	--icon	[app_name]	110	205
	ARGS	[builder.dmg]
	ARGS	[dmg_temp_dir]


##############################################################################################################
# Upload
##############################################################################################################

PUT	megabox-builds	builder.dmg
PUT	megabox-builds	build.log

PUT	s3-builds	builder.dmg
PUT	s3-builds	build.log
