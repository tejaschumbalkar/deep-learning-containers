#!/usr/bin/env bash

# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.

print_title() {
	echo ""
	echo "> $1"
	echo ""
}

setup_virtual_environment() {
	# setup virtual environment and install dependencies
	if [ ! -d env ]; then
		python3 -m venv env
		source ./env/bin/activate

		print_title "Install Dependencies"
		./env/bin/pip3 install -r test/requirements.txt

		print_title "Installed Dependencies"
		pip list
		source ./env/bin/deactivate
	fi
}

enter_virtual_environment() {
	# enter virtual environment if not already in one
	if [[ "$VIRTUAL_ENV" == "" ]]; then
		print_title "Enter Virtual Environment"
		source ./env/bin/activate
		echo "Virtual Environment: $VIRTUAL_ENV"
	fi
}

setup_environment_variables() {
	print_title "Set Environment Variables"
	unset PYTHONPATH

	# set PYTHONPATH
	if [[ "$CODEBUILD_SRC_DIR" != "" ]]; then
		export PYTHONPATH=$CODEBUILD_SRC_DIR
	else
		CURRENT_DIR=`echo $PWD`
		export PYTHONPATH=$CURRENT_DIR
	fi

    export DLC_IMAGES="	763104351884.dkr.ecr.us-west-2.amazonaws.com/tensorflow-training:2.3.1-gpu-py37-cu102-ubuntu18.04-v2.10"
	export TEST_TYPE=eks
	export BUILD_CONTEXT=PR 
	export REGION=us-west-2 
	export CODEBUILD_RESOLVED_SOURCE_VERSION=chumbalk 
	#DLC_IMAGES="501576597925.dkr.ecr.us-west-2.amazonaws.com/beta-tensorflow-training:2.3.1-cpu-py37-ubuntu18.04-2020-12-11-02-46-48"

	echo "PYTHONPATH=$PYTHONPATH"
	echo "DLAMI_CONFIG_DIR=$DLAMI_CONFIG_DIR"
}

run_smoke_test() {
	print_title "Run Smoke Test"
	cd $PYTHONPATH && python3 test/testrunner.py
	if [ $? -ne 0 ]; then
		echo "Smoke Test Failed!"
		return 1
	else
		return 0
	fi
}


#
# Setup and check basic things before run build
#

setup_virtual_environment
enter_virtual_environment
setup_environment_variables
run_smoke_test